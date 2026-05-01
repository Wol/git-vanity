#include <openssl/sha.h>
#include <iostream>
#include <sstream>
#include <iomanip>
#include <thread>
#include <vector>
#include <atomic>
#include <nlohmann/json.hpp>
#include <chrono>
#include <cstring>
#include <cinttypes>


using json = nlohmann::json;


std::atomic<bool> found(false);
std::string result_nonce;
std::string result_hash;

std::string sha1_hex(const std::string &input) {
    unsigned char hash[SHA_DIGEST_LENGTH];
    SHA1(reinterpret_cast<const unsigned char*>(input.c_str()), input.size(), hash);

    std::stringstream ss;
    for (int i = 0; i < SHA_DIGEST_LENGTH; i++) {
        ss << std::hex << std::setw(2) << std::setfill('0') << (int)hash[i];
    }
    return ss.str();
}

#include <iostream>
#include <iomanip>
#include <string>
#include <cctype>

void print_hex(const std::string &data) {

    const size_t width = 16;

    std::cout << "Hex dump (" << data.size() << " bytes):\n";

    for (size_t i = 0; i < data.size(); i += width) {
        // offset
        std::cout << std::setw(8) << std::setfill('0') << std::hex << i << "  ";

        // hex section
        for (size_t j = 0; j < width; j++) {
            if (i + j < data.size()) {
                unsigned char c = static_cast<unsigned char>(data[i + j]);
                std::cout << std::setw(2) << std::setfill('0')
                          << std::hex << (int)c << " ";
            } else {
                std::cout << "   ";
            }
        }

        std::cout << " ";

        // ASCII section
        for (size_t j = 0; j < width; j++) {
            if (i + j < data.size()) {
                unsigned char c = static_cast<unsigned char>(data[i + j]);

                if (std::isprint(c)) {
                    std::cout << c;
                } else {
                    std::cout << ".";
                }
            } else {
                std::cout << " ";
            }
        }

        std::cout << "\n";
    }

    std::cout << std::dec; // reset stream back to decimal
}


struct PrefixMatcher {
    uint64_t val;
    uint64_t mask;

    PrefixMatcher(const std::string &hex) {
        int bits = (int)hex.size() * 4;
        val = std::stoull(hex, nullptr, 16) << (64 - bits);
        mask = ~0ULL << (64 - bits);
    }

    bool matches(const unsigned char *hash) const {
        uint64_t h = ((uint64_t)hash[0] << 56) | ((uint64_t)hash[1] << 48) |
                     ((uint64_t)hash[2] << 40) | ((uint64_t)hash[3] << 32) |
                     ((uint64_t)hash[4] << 24) | ((uint64_t)hash[5] << 16) |
                     ((uint64_t)hash[6] <<  8) | (uint64_t)hash[7];
        return (h & mask) == val;
    }
};


// Returns the static body prefix: "tree T\n[parent P\n]author A\ncommitter C\n\nM\nnonce: "
// Worker appends the nonce digits and "\n" to form the full body, then prepends the git header.
std::string build_commit_object(const std::string &tree,
                                const std::string &parent,
                                const std::string &author,
                                const std::string &committer,
                                const std::string &message) {
    std::string s;
    s.reserve(128 + tree.size() + parent.size() + author.size() + committer.size() + message.size());
    s += "tree "; s += tree; s += "\n";
    if (!parent.empty()) { s += "parent "; s += parent; s += "\n"; }
    s += "author "; s += author; s += "\n";
    s += "committer "; s += committer; s += "\n\n";
    s += message; s += "\nnonce: ";
    return s;
}

void worker(int id,
            const PrefixMatcher &matcher,
            const std::string &body_prefix,
            int threads) {

    uint64_t nonce = id;
    int step = threads;

    constexpr size_t NONCE_DIGITS = 16;
    size_t body_size = body_prefix.size() + NONCE_DIGITS + 1; // +1 for trailing '\nCr'
    std::string hdr = "commit " + std::to_string(body_size);

    std::string commit_obj(hdr.size() + 1 + body_size, '\0');
    char *p = &commit_obj[0];
    std::memcpy(p, hdr.data(), hdr.size()); p += hdr.size();
    *p++ = '\0';
    std::memcpy(p, body_prefix.data(), body_prefix.size()); p += body_prefix.size();
    const size_t nonce_offset = (size_t)(p - &commit_obj[0]);
    p += NONCE_DIGITS;
    *p = '\n';

    char nonce_buf[NONCE_DIGITS + 1];
    unsigned char hash[SHA_DIGEST_LENGTH];

    while (!found.load(std::memory_order_relaxed)) {
        snprintf(nonce_buf, sizeof(nonce_buf), "%016" PRIu64, nonce);
        std::memcpy(&commit_obj[nonce_offset], nonce_buf, NONCE_DIGITS);

        SHA1(reinterpret_cast<const unsigned char*>(commit_obj.data()), commit_obj.size(), hash);

        if (matcher.matches(hash)) {
            found.store(true);
            result_nonce = nonce_buf;
            std::stringstream ss;
            for (int i = 0; i < SHA_DIGEST_LENGTH; i++)
                ss << std::hex << std::setw(2) << std::setfill('0') << (int)hash[i];
            result_hash = ss.str();
            print_hex(commit_obj);
            return;
        }

        nonce += step;
    }
}

int main() {

    json input;

    std::cin >> input;


    std::string prefix    = input["prefix"];
    std::string tree      = input["tree"];
    std::string parent    = input.value("parent", "");
    std::string author    = input["author"];
    std::string committer = input["committer"];
    std::string message   = input["message"];
    int cores_free        = input.value("cores_free", 0);

    // Baseline commit (no nonce)
    {
        std::string body;
        body += "tree "; body += tree; body += "\n";
        if (!parent.empty()) { body += "parent "; body += parent; body += "\n"; }
        body += "author "; body += author; body += "\n";
        body += "committer "; body += committer; body += "\n\n";
        body += message; body += "\n";
        std::string base_commit_obj = "commit " + std::to_string(body.size()) + '\0' + body;
        std::string base_hash = sha1_hex(base_commit_obj);

        std::cout << "----------------------------------\n";
        std::cout << "Baseline commit hash (no nonce):\n";
        std::cout << base_hash << "\n";
        std::cout << "----------------------------------\n";
        print_hex(base_commit_obj);
    }

    PrefixMatcher matcher(prefix);
    std::string body_prefix = build_commit_object(tree, parent, author, committer, message);

    int threads = std::max(1, (int)std::thread::hardware_concurrency() - cores_free);

    std::vector<std::thread> workers;

    std::cout << "Starting brute force with " << threads << " threads...\n";

    auto start_time = std::chrono::high_resolution_clock::now();

    for (int i = 0; i < threads; i++) {
        workers.emplace_back(worker, i, std::cref(matcher), std::cref(body_prefix), threads);
    }

    for (auto &t : workers) {
        t.join();
    }


    auto end_time = std::chrono::high_resolution_clock::now();

    std::cout << "\nFound!\n";

    std::chrono::duration<double> elapsed = end_time - start_time;

    std::cout << "\n----------------------------------\n";
    std::cout << "Time taken: " << elapsed.count() << " seconds\n";
    std::cout << "Hashes/sec (approx): "
          << (1.0 / elapsed.count()) * threads * 100000 << " (rough estimate)\n";
    std::cout << "----------------------------------\n";

    std::cout << "Hash:  " << result_hash << "\n";
    std::cout << "Nonce: " << result_nonce << "\n";


    json output;

    output["hash"] = result_hash;
    output["nonce"] = result_nonce;

    return 0;
}
