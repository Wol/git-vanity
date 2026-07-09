#include <git2.h>
#include <nlohmann/json.hpp>
#include <iostream>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <unistd.h>
#include <climits>
#include <cctype>

using json = nlohmann::json;

static void git_die(int err, const char *ctx) {
    if (err < 0) {
        const git_error *e = git_error_last();
        std::cerr << "{\"type\":\"error\",\"context\":\"" << ctx << "\",\"message\":\""
                  << (e ? e->message : "unknown git error") << "\"}\n";
        exit(1);
    }
}

// "Name <email> timestamp ±HHMM"
static std::string format_sig(const git_signature *s) {
    int off = s->when.offset;
    char tz[20];
    snprintf(tz, sizeof(tz), "%+03d%02d", off / 60, std::abs(off % 60));
    return std::string(s->name) + " <" + s->email + "> "
           + std::to_string((long long)s->when.time) + " " + tz;
}

// If `message` already ends with a trailer of the form "\n<label>: <digits>",
// it's a nonce line from a previous vanity pass (e.g. before this commit was
// rebased) rather than a genuine trailer — strip it so we replace the nonce
// in place instead of stacking a second one. A real "Co-authored-by:" line
// has a "Name <email>" value, never a bare digit string, so this can't
// mistake a real trailer for our own.
static std::string strip_existing_nonce_line(const std::string &message, const std::string &label) {
    std::string marker = "\n" + label + ": ";
    size_t pos = message.rfind(marker);
    if (pos == std::string::npos) return message;

    size_t digits_start = pos + marker.size();
    if (digits_start >= message.size()) return message;
    for (size_t i = digits_start; i < message.size(); ++i)
        if (!std::isdigit(static_cast<unsigned char>(message[i]))) return message;

    std::string stripped = message.substr(0, pos);
    while (!stripped.empty() && stripped.back() == ' ') stripped.pop_back();
    return stripped;
}

// $XDG_CONFIG_HOME/git-vanity/config.json, or ~/.config/git-vanity/config.json if
// XDG_CONFIG_HOME is unset/empty (per the XDG basedir spec). "" if neither
// XDG_CONFIG_HOME nor HOME is set.
static std::string global_config_path() {
    const char *xdg = getenv("XDG_CONFIG_HOME");
    if (xdg && xdg[0] != '\0') return std::string(xdg) + "/git-vanity/config.json";
    const char *home = getenv("HOME");
    if (home && home[0] != '\0') return std::string(home) + "/.config/git-vanity/config.json";
    return "";
}

// Pipe JSON into git_vanity via a temp file, echo output to stderr, return the "result" line
static json run_vanity(const json &input) {
    char tmp[] = "/tmp/git_vanity_XXXXXX";
    int fd = mkstemp(tmp);
    std::string s = input.dump();
    write(fd, s.c_str(), s.size());
    close(fd);

    std::string cmd = std::string("git_vanity < ") + tmp + " 2>&1";
    FILE *pipe = popen(cmd.c_str(), "r");
    if (!pipe) { unlink(tmp); throw std::runtime_error("failed to run git_vanity"); }

    std::string output;
    char buf[4096];
    while (fgets(buf, sizeof(buf), pipe)) {
        std::cerr << buf;
        output += buf;
    }
    pclose(pipe);
    unlink(tmp);

    std::istringstream ss(output);
    std::string line;
    while (std::getline(ss, line)) {
        if (line.empty()) continue;
        auto j = json::parse(line, nullptr, false);
        if (!j.is_discarded() && j.value("type", "") == "result")
            return j;
    }
    throw std::runtime_error("git_vanity produced no result line");
}

int main() {
    git_libgit2_init();

    git_repository *repo = nullptr;
    git_die(git_repository_open_ext(&repo, ".", GIT_REPOSITORY_OPEN_FROM_ENV, nullptr),
            "open repository");

    // Load .vanityconfig from repo root.
    // git_repository_workdir() returns NULL when the repo was opened via GIT_DIR (e.g. a
    // submodule gitdir at .git/modules/<name>) and libgit2 cannot resolve the worktree from
    // the config's worktree= entry.  Git always chdirs to the worktree root before running
    // hooks, so CWD is a reliable fallback.
    std::string workdir;
    if (const char *wd = git_repository_workdir(repo)) {
        workdir = wd;  // libgit2 always appends a trailing '/'
    } else {
        char cwd_buf[PATH_MAX];
        if (getcwd(cwd_buf, sizeof(cwd_buf))) {
            workdir = std::string(cwd_buf) + "/";
        }
    }
    // A repo's own .vanityconfig takes precedence; otherwise fall back to the
    // user's global default so most repos don't need one of their own at all.
    std::string local_path = workdir + ".vanityconfig";
    std::string global_path = global_config_path();

    std::string config_path;
    { std::ifstream test(local_path); if (test.is_open()) config_path = local_path; }
    if (config_path.empty() && !global_path.empty()) {
        std::ifstream test(global_path); if (test.is_open()) config_path = global_path;
    }
    if (config_path.empty()) {
        std::cerr << "{\"type\":\"error\",\"message\":\"no .vanityconfig found at " << local_path
                   << (global_path.empty() ? "" : " or " + global_path) << "\"}\n";
        return 1;
    }

    std::ifstream cfg_file(config_path);
    // allow_exceptions=true, ignore_comments=true — config may contain // and /* */ comments
    json config = json::parse(cfg_file, nullptr, true, true);

    // Read HEAD commit — must be run post-commit so the commit exists
    git_reference *head_ref = nullptr;
    git_die(git_repository_head(&head_ref, repo), "get HEAD");

    git_commit *commit = nullptr;
    git_die(git_reference_peel((git_object **)&commit, head_ref, GIT_OBJECT_COMMIT), "peel HEAD to commit");

    const git_signature *author    = git_commit_author(commit);
    const git_signature *committer = git_commit_committer(commit);

    char tree_sha[GIT_OID_HEXSZ + 1];
    git_oid_tostr(tree_sha, sizeof(tree_sha), git_commit_tree_id(commit));

    // Collect every parent — a merge commit has two or more, and dropping any
    // of them would rewrite the merge into an ordinary single-parent commit.
    std::vector<std::string> parents;
    unsigned int parent_count = git_commit_parentcount(commit);
    for (unsigned int i = 0; i < parent_count; ++i) {
        char buf[GIT_OID_HEXSZ + 1];
        git_oid_tostr(buf, sizeof(buf), git_commit_parent_id(commit, i));
        parents.emplace_back(buf);
    }

    // Strip trailing newlines from message
    std::string message = git_commit_message(commit);
    while (!message.empty() && message.back() == '\n') message.pop_back();

    // Drop any nonce trailer left over from a previous vanity pass (e.g. this
    // commit got rebased) so we overwrite it instead of adding a second one.
    std::string nonce_label = config.value("nonce_label", "nonce");
    message = strip_existing_nonce_line(message, nonce_label);

    // Build input for git_vanity, merging .vanityconfig fields
    json input = config;
    input["tree"]      = tree_sha;
    input["author"]    = format_sig(author);
    input["committer"] = format_sig(committer);
    input["message"]   = message;
    if (!parents.empty()) input["parents"] = parents;

    json result = run_vanity(input);
    std::string nonce = result["nonce"];
    std::string search_message = result.value("message", message);

    // Create amended commit via libgit2, preserving exact author/committer timestamps
    std::string new_message = search_message + "\nnonce: " + nonce + "\n";

    // git_vanity returns the exact commit body it computed the hash over.
    // Write it directly to the ODB so the SHA1 is guaranteed to match.
    std::string body = result["body"];

    git_odb *odb = nullptr;
    git_die(git_repository_odb(&odb, repo), "open odb");
    git_oid new_oid;
    git_die(git_odb_write(&new_oid, odb, body.data(), body.size(), GIT_OBJECT_COMMIT),
            "write commit object");
    git_odb_free(odb);

    char new_sha[GIT_OID_HEXSZ + 1];
    git_oid_tostr(new_sha, sizeof(new_sha), &new_oid);

    // Point HEAD's branch ref at the new commit
    git_reference *resolved = nullptr;
    git_die(git_reference_resolve(&resolved, head_ref), "resolve HEAD");
    git_reference *updated = nullptr;
    git_die(git_reference_set_target(&updated, resolved, &new_oid, "vanity-nonce"),
            "update HEAD");
    git_reference_free(updated);
    git_reference_free(resolved);



    std::cout << "{\"type\":\"done\",\"hash\":\"" << new_sha
              << "\",\"nonce\":\"" << nonce
              << "\"}\n";

    git_commit_free(commit);
    git_reference_free(head_ref);
    git_repository_free(repo);
    git_libgit2_shutdown();
    return 0;
}
