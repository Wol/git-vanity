#include <openssl/sha.h>
#include <iostream>
#include <sstream>
#include <iomanip>
#include <string>
#include <vector>
#include <cctype>
#include <nlohmann/json.hpp>
#include <chrono>
#include <cstring>
#include <cinttypes>
#include <cuda_runtime.h>

using json = nlohmann::json;

#define CUDA_CHECK(call) do { \
    cudaError_t _e = (call); \
    if (_e != cudaSuccess) { \
        std::cerr << "CUDA error: " << cudaGetErrorString(_e) \
                  << " (" << __FILE__ << ":" << __LINE__ << ")\n"; \
        exit(1); \
    } \
} while(0)

// ===== Host SHA1 (for precomputing static blocks) =====

static inline uint32_t rotl_h(uint32_t x, int n) { return (x << n) | (x >> (32 - n)); }

static void sha1_compress_h(uint32_t s[5], const uint8_t blk[64]) {
    uint32_t w[80];
    for (int i = 0; i < 16; i++)
        w[i] = ((uint32_t)blk[i*4]<<24) | ((uint32_t)blk[i*4+1]<<16) |
               ((uint32_t)blk[i*4+2]<< 8) | (uint32_t)blk[i*4+3];
    for (int i = 16; i < 80; i++)
        w[i] = rotl_h(w[i-3] ^ w[i-8] ^ w[i-14] ^ w[i-16], 1);
    uint32_t a=s[0], b=s[1], c=s[2], d=s[3], e=s[4];
    for (int i = 0; i < 80; i++) {
        uint32_t f, k;
        if      (i < 20) { f = (b & c) | (~b & d);           k = 0x5A827999u; }
        else if (i < 40) { f = b ^ c ^ d;                    k = 0x6ED9EBA1u; }
        else if (i < 60) { f = (b & c) | (b & d) | (c & d); k = 0x8F1BBCDCu; }
        else             { f = b ^ c ^ d;                    k = 0xCA62C1D6u; }
        uint32_t t = rotl_h(a, 5) + f + e + k + w[i];
        e=d; d=c; c=rotl_h(b,30); b=a; a=t;
    }
    s[0]+=a; s[1]+=b; s[2]+=c; s[3]+=d; s[4]+=e;
}

static std::string sha1_hex(const std::string &input) {
    unsigned char hash[SHA_DIGEST_LENGTH];
    SHA1(reinterpret_cast<const unsigned char*>(input.data()), input.size(), hash);
    std::stringstream ss;
    for (int i = 0; i < SHA_DIGEST_LENGTH; i++)
        ss << std::hex << std::setw(2) << std::setfill('0') << (int)hash[i];
    return ss.str();
}

// ===== Helpers =====

static void print_hex(const std::string &data) {
    const size_t W = 16;
    std::cout << "Hex dump (" << data.size() << " bytes):\n";
    for (size_t i = 0; i < data.size(); i += W) {
        std::cout << std::setw(8) << std::setfill('0') << std::hex << i << "  ";
        for (size_t j = 0; j < W; j++) {
            if (i+j < data.size())
                std::cout << std::setw(2) << std::setfill('0') << (int)(unsigned char)data[i+j] << " ";
            else
                std::cout << "   ";
        }
        std::cout << " ";
        for (size_t j = 0; j < W; j++) {
            if (i+j < data.size()) { unsigned char c = data[i+j]; std::cout << (std::isprint(c) ? (char)c : '.'); }
            else std::cout << " ";
        }
        std::cout << "\n";
    }
    std::cout << std::dec;
}

// Returns body prefix up to and including "nonce: "
static std::string build_body_prefix(const std::string &tree, const std::string &parent,
                                     const std::string &author, const std::string &committer,
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

// ===== CUDA constant memory =====

__constant__ uint32_t c_state[5];      // SHA1 state after all static blocks
__constant__ uint8_t  c_tmpl[128];     // padded nonce-block + optional padding-block (max 2 * 64 bytes)
__constant__ int      c_nonce_off;     // byte offset of nonce within c_tmpl
__constant__ int      c_tmpl_blocks;   // number of blocks in c_tmpl (1 or 2)
__constant__ uint64_t c_prefix_val;
__constant__ uint64_t c_prefix_mask;

// ===== CUDA device code =====

__device__ __forceinline__ uint32_t rotl32(uint32_t x, int n) {
    return (x << n) | (x >> (32 - n));
}

__device__ __forceinline__ void sha1_compress(uint32_t s[5], const uint8_t blk[64]) {
    uint32_t w[80];
    #pragma unroll
    for (int i = 0; i < 16; i++)
        w[i] = ((uint32_t)blk[i*4]<<24) | ((uint32_t)blk[i*4+1]<<16) |
               ((uint32_t)blk[i*4+2]<< 8) | (uint32_t)blk[i*4+3];
    #pragma unroll
    for (int i = 16; i < 80; i++)
        w[i] = rotl32(w[i-3] ^ w[i-8] ^ w[i-14] ^ w[i-16], 1);

    uint32_t a=s[0], b=s[1], c=s[2], d=s[3], e=s[4];
    #pragma unroll
    for (int i =  0; i < 20; i++) { uint32_t t=rotl32(a,5)+((b&c)|(~b&d))+e+0x5A827999u+w[i]; e=d;d=c;c=rotl32(b,30);b=a;a=t; }
    #pragma unroll
    for (int i = 20; i < 40; i++) { uint32_t t=rotl32(a,5)+(b^c^d)+e+0x6ED9EBA1u+w[i];         e=d;d=c;c=rotl32(b,30);b=a;a=t; }
    #pragma unroll
    for (int i = 40; i < 60; i++) { uint32_t t=rotl32(a,5)+((b&c)|(b&d)|(c&d))+e+0x8F1BBCDCu+w[i]; e=d;d=c;c=rotl32(b,30);b=a;a=t; }
    #pragma unroll
    for (int i = 60; i < 80; i++) { uint32_t t=rotl32(a,5)+(b^c^d)+e+0xCA62C1D6u+w[i];         e=d;d=c;c=rotl32(b,30);b=a;a=t; }
    s[0]+=a; s[1]+=b; s[2]+=c; s[3]+=d; s[4]+=e;
}

__device__ __forceinline__ void write_nonce(uint8_t *buf, uint64_t n) {
    for (int i = 15; i >= 0; i--) { buf[i] = '0' + (int)(n % 10); n /= 10; }
}

__global__ void search_kernel(uint64_t base_nonce, uint64_t *d_result, int *d_found) {
    if (*d_found) return;

    uint64_t nonce = base_nonce + (uint64_t)blockIdx.x * blockDim.x + threadIdx.x;

    // Copy the block template(s) into registers/local memory and write this thread's nonce
    uint8_t blk0[64], blk1[64];
    #pragma unroll
    for (int i = 0; i < 64; i++) blk0[i] = c_tmpl[i];
    #pragma unroll
    for (int i = 0; i < 64; i++) blk1[i] = c_tmpl[64 + i];

    write_nonce(blk0 + c_nonce_off, nonce);

    // Continue SHA1 from precomputed state
    uint32_t s[5] = { c_state[0], c_state[1], c_state[2], c_state[3], c_state[4] };
    sha1_compress(s, blk0);
    if (c_tmpl_blocks == 2) sha1_compress(s, blk1);

    // Compare first 64 bits of hash (stored in s[0]:s[1] big-endian) against prefix
    uint64_t h = ((uint64_t)s[0] << 32) | (uint64_t)s[1];
    if ((h & c_prefix_mask) == c_prefix_val)
        if (atomicExch(d_found, 1) == 0)
            *d_result = nonce;
}

// ===== main =====

int main() {
    json input;
    std::cin >> input;

    std::string prefix    = input["prefix"];
    std::string tree      = input["tree"];
    std::string parent    = input.value("parent", "");
    std::string author    = input["author"];
    std::string committer = input["committer"];
    std::string message   = input["message"];

    // Baseline commit (no nonce)
    {
        std::string body;
        body += "tree "; body += tree; body += "\n";
        if (!parent.empty()) { body += "parent "; body += parent; body += "\n"; }
        body += "author "; body += author; body += "\n";
        body += "committer "; body += committer; body += "\n\n";
        body += message; body += "\n";
        std::string base_obj = "commit " + std::to_string(body.size()) + '\0' + body;
        std::cout << "----------------------------------\n";
        std::cout << "Baseline commit hash (no nonce):\n" << sha1_hex(base_obj) << "\n";
        std::cout << "----------------------------------\n";
        print_hex(base_obj);
    }

    // Build commit object template with zero-filled nonce placeholder
    constexpr size_t NONCE_DIGITS = 16;
    std::string body_prefix = build_body_prefix(tree, parent, author, committer, message);
    size_t body_size  = body_prefix.size() + NONCE_DIGITS + 1; // +1 for trailing '\n'
    std::string hdr   = "commit " + std::to_string(body_size);
    size_t total_size = hdr.size() + 1 + body_size;

    std::string commit_tmpl(total_size, '\0');
    {
        char *p = &commit_tmpl[0];
        memcpy(p, hdr.data(), hdr.size()); p += hdr.size();
        *p++ = '\0';
        memcpy(p, body_prefix.data(), body_prefix.size()); p += body_prefix.size();
        memset(p, '0', NONCE_DIGITS); p += NONCE_DIGITS;
        *p = '\n';
    }
    const size_t nonce_offset    = hdr.size() + 1 + body_prefix.size();
    const int    nonce_block     = (int)(nonce_offset / 64);
    const int    nonce_off_in_blk = (int)(nonce_offset % 64);

    if (nonce_off_in_blk + (int)NONCE_DIGITS > 64) {
        std::cerr << "Nonce spans a SHA1 block boundary — not supported\n";
        return 1;
    }

    // Precompute SHA1 state through all blocks before the nonce block (purely static data)
    uint32_t precomp[5] = { 0x67452301u, 0xEFCDAB89u, 0x98BADCFEu, 0x10325476u, 0xC3D2E1F0u };
    for (int b = 0; b < nonce_block; b++)
        sha1_compress_h(precomp, reinterpret_cast<const uint8_t*>(commit_tmpl.data()) + b * 64);

    // Build the padded remaining data the GPU will process (nonce block onwards + SHA1 padding)
    size_t rem_start = (size_t)nonce_block * 64;
    std::vector<uint8_t> padded(commit_tmpl.begin() + rem_start, commit_tmpl.end());
    padded.push_back(0x80);
    while (padded.size() % 64 != 56) padded.push_back(0x00);
    uint64_t bit_len = (uint64_t)total_size * 8;
    for (int i = 7; i >= 0; i--) padded.push_back((uint8_t)(bit_len >> (i * 8)));

    int tmpl_blocks = (int)(padded.size() / 64);
    if (tmpl_blocks > 2) {
        std::cerr << "Commit object too large: " << tmpl_blocks << " remaining blocks (max 2 supported)\n";
        return 1;
    }

    uint8_t tmpl128[128] = {};
    memcpy(tmpl128, padded.data(), padded.size());

    uint64_t pval  = std::stoull(prefix, nullptr, 16) << (64 - (int)prefix.size() * 4);
    uint64_t pmask = ~0ULL << (64 - (int)prefix.size() * 4);

    CUDA_CHECK(cudaMemcpyToSymbol(c_state,       precomp,            5 * sizeof(uint32_t)));
    CUDA_CHECK(cudaMemcpyToSymbol(c_tmpl,        tmpl128,            128));
    CUDA_CHECK(cudaMemcpyToSymbol(c_nonce_off,   &nonce_off_in_blk,  sizeof(int)));
    CUDA_CHECK(cudaMemcpyToSymbol(c_tmpl_blocks, &tmpl_blocks,       sizeof(int)));
    CUDA_CHECK(cudaMemcpyToSymbol(c_prefix_val,  &pval,              sizeof(uint64_t)));
    CUDA_CHECK(cudaMemcpyToSymbol(c_prefix_mask, &pmask,             sizeof(uint64_t)));

    uint64_t *d_result; int *d_found;
    CUDA_CHECK(cudaMalloc(&d_result, sizeof(uint64_t)));
    CUDA_CHECK(cudaMalloc(&d_found,  sizeof(int)));
    uint64_t init_r = UINT64_MAX; int init_f = 0;
    CUDA_CHECK(cudaMemcpy(d_result, &init_r, sizeof(uint64_t), cudaMemcpyHostToDevice));
    CUDA_CHECK(cudaMemcpy(d_found,  &init_f, sizeof(int),      cudaMemcpyHostToDevice));

    constexpr int      THREADS = 256;
    constexpr uint64_t BATCH   = 1ULL << 26; // 64M nonces per launch
    const     int      GRIDS   = (int)(BATCH / THREADS);

    std::cout << "GPU: " << GRIDS << " blocks x " << THREADS << " threads, "
              << (BATCH >> 20) << "M nonces/launch\n";

    auto t0 = std::chrono::high_resolution_clock::now();

    uint64_t base = 0;
    int h_found = 0;
    while (!h_found) {
        search_kernel<<<GRIDS, THREADS>>>(base, d_result, d_found);
        CUDA_CHECK(cudaGetLastError());
        CUDA_CHECK(cudaDeviceSynchronize());
        base += BATCH;
        CUDA_CHECK(cudaMemcpy(&h_found, d_found, sizeof(int), cudaMemcpyDeviceToHost));

        double secs = std::chrono::duration<double>(std::chrono::high_resolution_clock::now() - t0).count();
        double ghs  = (double)base / secs / 1e9;
        std::cout << "\r  " << std::fixed << std::setprecision(3)
                  << (double)base / 1e9 << " GH  |  "
                  << std::setprecision(2) << ghs << " GH/s  |  nonce: "
                  << std::setw(16) << std::setfill('0') << std::hex << base << std::dec
                  << std::setfill(' ') << std::flush;
    }
    std::cout << "\n";

    uint64_t h_result;
    CUDA_CHECK(cudaMemcpy(&h_result, d_result, sizeof(uint64_t), cudaMemcpyDeviceToHost));

    auto t1 = std::chrono::high_resolution_clock::now();
    std::chrono::duration<double> elapsed = t1 - t0;

    // Reconstruct and verify winning commit object on CPU
    char nonce_buf[NONCE_DIGITS + 1];
    snprintf(nonce_buf, sizeof(nonce_buf), "%016" PRIu64, h_result);
    std::string win_commit = commit_tmpl;
    memcpy(&win_commit[nonce_offset], nonce_buf, NONCE_DIGITS);
    std::string win_hash = sha1_hex(win_commit);

    std::cout << "\nFound!\n";
    print_hex(win_commit);
    std::cout << "\n----------------------------------\n";
    std::cout << "Time:       " << elapsed.count() << " s\n";
    std::cout << "Hashes/sec: " << (double)base / elapsed.count() << "\n";
    std::cout << "----------------------------------\n";
    std::cout << "Hash:  " << win_hash << "\n";
    std::cout << "Nonce: " << nonce_buf << "\n";

    json output;
    output["hash"]  = win_hash;
    output["nonce"] = nonce_buf;

    cudaFree(d_result);
    cudaFree(d_found);
    return 0;
}
