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

// Returns body prefix up to and including "<nonce_label>: "
static std::string build_body_prefix(const std::string &tree, const std::string &parent,
                                     const std::string &author, const std::string &committer,
                                     const std::string &message,
                                     const std::string &nonce_label = "nonce") {
    std::string s;
    s.reserve(128 + tree.size() + parent.size() + author.size() + committer.size() + message.size());
    s += "tree "; s += tree; s += "\n";
    if (!parent.empty()) { s += "parent "; s += parent; s += "\n"; }
    s += "author "; s += author; s += "\n";
    s += "committer "; s += committer; s += "\n\n";
    s += message; s += "\n"; s += nonce_label; s += ": ";
    return s;
}

// ===== CUDA constant memory =====

__constant__ uint32_t c_state[5];      // SHA1 state after all static blocks
__constant__ uint8_t  c_tmpl[128];     // padded nonce-block + optional padding-block (max 2 * 64 bytes)
__constant__ int      c_nonce_off;     // byte offset of nonce within c_tmpl
__constant__ int      c_tmpl_blocks;   // number of blocks in c_tmpl (1 or 2)
__constant__ uint64_t c_prefix_val;
__constant__ uint64_t c_prefix_mask;
__constant__ int      c_pairs_count;   // number of leading bytes that must have paired nibbles
__constant__ int      c_repeat_count;  // X: first X bytes must equal bytes X..2X-1

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

// Returns true if all 4 bytes of a uint32 have matching high/low nibbles (e.g. 0xAA, 0xBB)
__device__ __forceinline__ bool nibbles_paired(uint32_t w) {
    return ((w ^ (w >> 4)) & 0x0F0F0F0Fu) == 0;
}

__global__ void search_kernel_pairs(uint64_t base_nonce, uint64_t *d_result, int *d_found) {
    if (*d_found) return;

    uint64_t nonce = base_nonce + (uint64_t)blockIdx.x * blockDim.x + threadIdx.x;

    uint8_t blk0[64], blk1[64];
    #pragma unroll
    for (int i = 0; i < 64; i++) blk0[i] = c_tmpl[i];
    #pragma unroll
    for (int i = 0; i < 64; i++) blk1[i] = c_tmpl[64 + i];

    write_nonce(blk0 + c_nonce_off, nonce);

    uint32_t s[5] = { c_state[0], c_state[1], c_state[2], c_state[3], c_state[4] };
    sha1_compress(s, blk0);
    if (c_tmpl_blocks == 2) sha1_compress(s, blk1);

    // Check that the first c_pairs_count bytes all have paired nibbles
    int full_words = c_pairs_count / 4;
    int rem_bytes  = c_pairs_count % 4;

    bool match = true;
    for (int i = 0; i < full_words; i++)
        match = match && nibbles_paired(s[i]);

    if (match && rem_bytes > 0) {
        uint32_t mask = 0xFFFFFFFFu << ((4 - rem_bytes) * 8);
        match = ((s[full_words] ^ (s[full_words] >> 4)) & 0x0F0F0F0Fu & mask) == 0;
    }

    if (match)
        if (atomicExch(d_found, 1) == 0)
            *d_result = nonce;
}

__global__ void search_kernel_repeat(uint64_t base_nonce, uint64_t *d_result, int *d_found) {
    if (*d_found) return;

    uint64_t nonce = base_nonce + (uint64_t)blockIdx.x * blockDim.x + threadIdx.x;

    uint8_t blk0[64], blk1[64];
    #pragma unroll
    for (int i = 0; i < 64; i++) blk0[i] = c_tmpl[i];
    #pragma unroll
    for (int i = 0; i < 64; i++) blk1[i] = c_tmpl[64 + i];

    write_nonce(blk0 + c_nonce_off, nonce);

    uint32_t s[5] = { c_state[0], c_state[1], c_state[2], c_state[3], c_state[4] };
    sha1_compress(s, blk0);
    if (c_tmpl_blocks == 2) sha1_compress(s, blk1);

    // Check hash[0..X-1] == hash[X..2X-1]
    bool match = true;
    for (int i = 0; i < c_repeat_count; i++) {
        uint8_t a = (s[i/4]           >> (24 - (i%4)*8))           & 0xFF;
        uint8_t b = (s[(i+c_repeat_count)/4] >> (24 - ((i+c_repeat_count)%4)*8)) & 0xFF;
        if (a != b) { match = false; break; }
    }

    if (match)
        if (atomicExch(d_found, 1) == 0)
            *d_result = nonce;
}

// ===== main =====

int main() {
    json input;
    std::cin >> input;

    std::string mode        = input.value("mode", "prefix"); // "prefix", "pairs", or "repeat"
    std::string prefix      = input.value("prefix", "");
    int         pairs_count  = input.value("pairs_count", 4);
    int         repeat_count = input.value("repeat_count", 4);
    std::string tree        = input["tree"];
    std::string parent      = input.value("parent", "");
    std::string author      = input["author"];
    std::string committer   = input["committer"];
    std::string message     = input["message"];
    std::string nonce_label = input.value("nonce_label", "nonce");

    auto emit = [](json j) { std::cout << j.dump() << "\n" << std::flush; };

    // Baseline commit (no nonce)
    {
        std::string body;
        body += "tree "; body += tree; body += "\n";
        if (!parent.empty()) { body += "parent "; body += parent; body += "\n"; }
        body += "author "; body += author; body += "\n";
        body += "committer "; body += committer; body += "\n\n";
        body += message; body += "\n";
        std::string base_obj = "commit " + std::to_string(body.size()) + '\0' + body;
        emit({{"type","info"},{"baseline_hash", sha1_hex(base_obj)},{"mode", mode}});
    }

    // Build commit object template with zero-filled nonce placeholder.
    // If the 16-digit nonce would straddle a 64-byte SHA1 block boundary the
    // GPU kernel can only see one block of dynamic data, so pad the message
    // with trailing spaces until the nonce fits entirely within one block.
    constexpr size_t NONCE_DIGITS = 16;
    std::string search_message = message;
    std::string body_prefix;
    std::string hdr;
    size_t nonce_offset = 0;
    int nonce_block = 0;
    int nonce_off_in_blk = 0;
    while (true) {
        body_prefix = build_body_prefix(tree, parent, author, committer, search_message, nonce_label);
        size_t body_size = body_prefix.size() + NONCE_DIGITS + 1;
        hdr = "commit " + std::to_string(body_size);
        nonce_offset = hdr.size() + 1 + body_prefix.size();
        nonce_block = (int)(nonce_offset / 64);
        nonce_off_in_blk = (int)(nonce_offset % 64);
        if (nonce_off_in_blk + (int)NONCE_DIGITS <= 64) break;
        search_message += ' ';
    }

    size_t body_size  = body_prefix.size() + NONCE_DIGITS + 1;
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
        emit({{"type","error"},{"message","commit object too large"},{"remaining_blocks", tmpl_blocks}});
        return 1;
    }

    uint8_t tmpl128[128] = {};
    memcpy(tmpl128, padded.data(), padded.size());

    uint64_t pval  = prefix.empty() ? 0 : std::stoull(prefix, nullptr, 16) << (64 - (int)prefix.size() * 4);
    uint64_t pmask = prefix.empty() ? 0 : ~0ULL << (64 - (int)prefix.size() * 4);

    CUDA_CHECK(cudaMemcpyToSymbol(c_state,        precomp,            5 * sizeof(uint32_t)));
    CUDA_CHECK(cudaMemcpyToSymbol(c_tmpl,         tmpl128,            128));
    CUDA_CHECK(cudaMemcpyToSymbol(c_nonce_off,    &nonce_off_in_blk,  sizeof(int)));
    CUDA_CHECK(cudaMemcpyToSymbol(c_tmpl_blocks,  &tmpl_blocks,       sizeof(int)));
    CUDA_CHECK(cudaMemcpyToSymbol(c_prefix_val,   &pval,              sizeof(uint64_t)));
    CUDA_CHECK(cudaMemcpyToSymbol(c_prefix_mask,  &pmask,             sizeof(uint64_t)));
    CUDA_CHECK(cudaMemcpyToSymbol(c_pairs_count,  &pairs_count,       sizeof(int)));
    CUDA_CHECK(cudaMemcpyToSymbol(c_repeat_count, &repeat_count,      sizeof(int)));

    uint64_t *d_result; int *d_found;
    CUDA_CHECK(cudaMalloc(&d_result, sizeof(uint64_t)));
    CUDA_CHECK(cudaMalloc(&d_found,  sizeof(int)));
    uint64_t init_r = UINT64_MAX; int init_f = 0;
    CUDA_CHECK(cudaMemcpy(d_result, &init_r, sizeof(uint64_t), cudaMemcpyHostToDevice));
    CUDA_CHECK(cudaMemcpy(d_found,  &init_f, sizeof(int),      cudaMemcpyHostToDevice));

    constexpr int      THREADS = 256;
    constexpr uint64_t BATCH   = 1ULL << 26; // 64M nonces per launch
    const     int      GRIDS   = (int)(BATCH / THREADS);

    auto t0 = std::chrono::high_resolution_clock::now();

    uint64_t base = 0;
    int h_found = 0;
    while (!h_found) {
        if (mode == "pairs")
            search_kernel_pairs<<<GRIDS, THREADS>>>(base, d_result, d_found);
        else if (mode == "repeat")
            search_kernel_repeat<<<GRIDS, THREADS>>>(base, d_result, d_found);
        else
            search_kernel<<<GRIDS, THREADS>>>(base, d_result, d_found);
        CUDA_CHECK(cudaGetLastError());
        CUDA_CHECK(cudaDeviceSynchronize());
        base += BATCH;
        CUDA_CHECK(cudaMemcpy(&h_found, d_found, sizeof(int), cudaMemcpyDeviceToHost));

        double secs = std::chrono::duration<double>(std::chrono::high_resolution_clock::now() - t0).count();
        emit({{"type","progress"},{"hashes_tried", base},{"hashes_per_sec", (uint64_t)(base / secs)}});
    }

    uint64_t h_result;
    CUDA_CHECK(cudaMemcpy(&h_result, d_result, sizeof(uint64_t), cudaMemcpyDeviceToHost));

    auto t1 = std::chrono::high_resolution_clock::now();
    double elapsed = std::chrono::duration<double>(t1 - t0).count();

    char nonce_buf[NONCE_DIGITS + 1];
    snprintf(nonce_buf, sizeof(nonce_buf), "%016" PRIu64, h_result);
    std::string win_commit = commit_tmpl;
    memcpy(&win_commit[nonce_offset], nonce_buf, NONCE_DIGITS);
    std::string win_hash = sha1_hex(win_commit);
    std::string win_body = win_commit.substr(hdr.size() + 1); // strip "commit <size>\0"

    emit({{"type","result"},{"hash", win_hash},{"nonce", nonce_buf},{"message", search_message},
          {"body", win_body},
          {"time_s", elapsed},{"hashes_per_sec", (uint64_t)(base / elapsed)}});

    cudaFree(d_result);
    cudaFree(d_found);
    return 0;
}
