// C API for Swift interop. Thin wrapper around msplat C++ types.
// Opaque handles + free functions — works with any Swift version.

#ifndef MSPLAT_C_API_H
#define MSPLAT_C_API_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ── Config ──────────────────────────────────────────────────────────────────

typedef struct {
    int iterations;
    int shDegree;
    int shDegreeInterval;
    float ssimWeight;
    int numDownscales;
    int resolutionSchedule;
    int refineEvery;
    int warmupLength;
    int resetAlphaEvery;
    float densifyGradThresh;
    float densifySizeThresh;
    int stopScreenSizeAt;
    float splitScreenSize;
    bool keepCrs;
    float downscaleFactor;
    float bgColor[3];
} MsplatConfig;

static inline MsplatConfig msplat_default_config(void) {
    MsplatConfig c;
    c.iterations = 30000;
    c.shDegree = 3;
    c.shDegreeInterval = 1000;
    c.ssimWeight = 0.2f;
    c.numDownscales = 2;
    c.resolutionSchedule = 3000;
    c.refineEvery = 100;
    c.warmupLength = 500;
    c.resetAlphaEvery = 30;
    c.densifyGradThresh = 0.0002f;
    c.densifySizeThresh = 0.01f;
    c.stopScreenSizeAt = 4000;
    c.splitScreenSize = 0.05f;
    c.keepCrs = false;
    c.downscaleFactor = 1.0f;
    c.bgColor[0] = 0.6130f; c.bgColor[1] = 0.0101f; c.bgColor[2] = 0.3984f;
    return c;
}

// ── Stats ───────────────────────────────────────────────────────────────────

typedef struct {
    int iteration;
    int splatCount;
    float msPerStep;
} MsplatStats;

typedef struct {
    float psnr;
    float ssim;
    float l1;
    int numTest;
    int numGaussians;
} MsplatEvalMetrics;

// ── Pixel buffer ────────────────────────────────────────────────────────────

typedef struct {
    float* data;   // RGB float32, HWC layout. Caller must free() this.
    int width;
    int height;
} MsplatPixelBuffer;

// ── Dataset ─────────────────────────────────────────────────────────────────

typedef void* MsplatDataset;

MsplatDataset msplat_dataset_create(const char* path, float downscaleFactor,
                                     bool evalMode, int testEvery);
// Synthetic single-camera dataset (no files) for rendering a standalone
// .ply: pair with msplat_trainer_load_ply. width/height set the render
// resolution; fovYDeg the vertical field of view.
MsplatDataset msplat_dataset_create_synthetic(int width, int height, float fovYDeg);
void msplat_dataset_destroy(MsplatDataset ds);
int msplat_dataset_num_train(MsplatDataset ds);
int msplat_dataset_num_test(MsplatDataset ds);

// ── Trainer ─────────────────────────────────────────────────────────────────

typedef void* MsplatTrainer;

MsplatTrainer msplat_trainer_create(MsplatDataset ds, MsplatConfig config);
void msplat_trainer_destroy(MsplatTrainer t);

MsplatStats msplat_trainer_step(MsplatTrainer t);
void msplat_trainer_train(MsplatTrainer t);
MsplatEvalMetrics msplat_trainer_evaluate(MsplatTrainer t);
MsplatPixelBuffer msplat_trainer_render(MsplatTrainer t, int cameraIndex, bool useTest);
MsplatPixelBuffer msplat_trainer_render_pose(MsplatTrainer t, const float camToWorld[16], int refCameraIndex);

/// Render into a caller-provided RGBA uint8 buffer (no allocation, no float copy).
/// outRGBA must be at least width*height*4 bytes. Returns dimensions via outWidth/outHeight.
/// Call once with outRGBA=NULL to get dimensions, then allocate and call again.
void msplat_trainer_render_pose_to_buffer(MsplatTrainer t, const float camToWorld[16],
                                      int refCameraIndex, uint8_t* outRGBA,
                                      int* outWidth, int* outHeight);
void msplat_trainer_export_ply(MsplatTrainer t, const char* path);
void msplat_trainer_export_splat(MsplatTrainer t, const char* path);
void msplat_trainer_save_checkpoint(MsplatTrainer t, const char* path);
int msplat_trainer_load_checkpoint(MsplatTrainer t, const char* path);
// Replaces the scene with a standalone .ply (view-only). Returns iteration.
int msplat_trainer_load_ply(MsplatTrainer t, const char* path);
int msplat_trainer_splat_count(MsplatTrainer t);
int msplat_trainer_iteration(MsplatTrainer t);
void msplat_dataset_camera_pose(MsplatDataset ds, int cameraIndex, float camToWorld[16]);

// ── Editing (Splat Studio) ──────────────────────────────────────────────────
// Read back per-gaussian attributes for selection UIs. `out` must hold
// maxCount*3 floats for means, maxCount floats otherwise. Returns the number
// of gaussians copied. Opacities are post-sigmoid; maxScales in world units.
int msplat_trainer_read_means(MsplatTrainer t, float* out, int maxCount);
int msplat_trainer_read_opacities(MsplatTrainer t, float* out, int maxCount);
int msplat_trainer_read_max_scales(MsplatTrainer t, float* out, int maxCount);
// Remove gaussians by index (unsorted OK, duplicates OK). Returns new count.
int msplat_trainer_remove_indices(MsplatTrainer t, const int32_t* indices, int count);
// Keep only gaussians inside the box / within the sphere. Return new count.
int msplat_trainer_crop_box(MsplatTrainer t, const float minXYZ[3], const float maxXYZ[3]);
int msplat_trainer_crop_sphere(MsplatTrainer t, const float center[3], float radius);
// Remove gaussians below the opacity floor and/or above the world-size
// ceiling; pass <=0 to skip a criterion. Returns new count.
int msplat_trainer_cleanup(MsplatTrainer t, float minOpacity, float maxWorldScale);
// Rigid-transform the whole scene (row-major 4x4; rotation+translation and
// uniform scale). SH coefficients are not re-rotated.
void msplat_trainer_transform(MsplatTrainer t, const float matrix[16]);
// Frees Adam optimizer moments (~2/3 of per-gaussian session memory). Use
// for view/edit-only sessions (preview); do not train afterwards.
void msplat_trainer_release_optimizer_state(MsplatTrainer t);

// ── Lifecycle ───────────────────────────────────────────────────────────────

void msplat_set_metallib_path(const char* path);
void msplat_sync(void);
void msplat_cleanup(void);

#ifdef __cplusplus
}
#endif

#endif // MSPLAT_C_API_H
