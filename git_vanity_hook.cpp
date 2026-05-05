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

    // Load .vanityconfig from repo root
    std::string workdir = git_repository_workdir(repo) ? git_repository_workdir(repo) : "";
    std::string config_path = workdir + ".vanityconfig";
    std::ifstream cfg_file(config_path);
    if (!cfg_file.is_open()) {
        std::cerr << "{\"type\":\"error\",\"message\":\"no .vanityconfig found at " << config_path << "\"}\n";
        return 1;
    }
    json config;
    cfg_file >> config;

    // Read HEAD commit — must be run post-commit so the commit exists
    git_reference *head_ref = nullptr;
    git_die(git_repository_head(&head_ref, repo), "get HEAD");

    git_commit *commit = nullptr;
    git_die(git_reference_peel((git_object **)&commit, head_ref, GIT_OBJECT_COMMIT), "peel HEAD to commit");

    const git_signature *author    = git_commit_author(commit);
    const git_signature *committer = git_commit_committer(commit);

    char tree_sha[GIT_OID_HEXSZ + 1];
    git_oid_tostr(tree_sha, sizeof(tree_sha), git_commit_tree_id(commit));

    std::string parent_sha;
    if (git_commit_parentcount(commit) > 0) {
        char buf[GIT_OID_HEXSZ + 1];
        git_oid_tostr(buf, sizeof(buf), git_commit_parent_id(commit, 0));
        parent_sha = buf;
    }

    // Strip trailing newlines from message
    std::string message = git_commit_message(commit);
    while (!message.empty() && message.back() == '\n') message.pop_back();

    // Build input for git_vanity, merging .vanityconfig fields
    json input = config;
    input["tree"]      = tree_sha;
    input["author"]    = format_sig(author);
    input["committer"] = format_sig(committer);
    input["message"]   = message;
    if (!parent_sha.empty()) input["parent"] = parent_sha;

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
