// The parts of sherpa-onnx v1.13.8's C API that Jarvis uses, copied exactly, because the layout has to match
// that version's library. Jarvis loads the library at runtime and only if the Kokoro voice is chosen.
// sherpa-onnx is Copyright (c) Xiaomi Corporation and licensed under Apache-2.0.
#ifndef CSHERPA_ONNX_H
#define CSHERPA_ONNX_H
#include <stdint.h>


typedef struct SherpaOnnxOfflineTtsVitsModelConfig {
  const char *model;
  const char *lexicon;
  const char *tokens;
  const char *data_dir;
  float noise_scale;
  float noise_scale_w;
  float length_scale;
  const char *dict_dir;
} SherpaOnnxOfflineTtsVitsModelConfig;

typedef struct SherpaOnnxOfflineTtsMatchaModelConfig {
  const char *acoustic_model;
  const char *vocoder;
  const char *lexicon;
  const char *tokens;
  const char *data_dir;
  float noise_scale;
  float length_scale;
  const char *dict_dir;
} SherpaOnnxOfflineTtsMatchaModelConfig;

typedef struct SherpaOnnxOfflineTtsKokoroModelConfig {
  const char *model;
  const char *voices;
  const char *tokens;
  const char *data_dir;
  float length_scale;
  const char *dict_dir;
  const char *lexicon;
  const char *lang;
} SherpaOnnxOfflineTtsKokoroModelConfig;

typedef struct SherpaOnnxOfflineTtsKittenModelConfig {
  const char *model;
  const char *voices;
  const char *tokens;
  const char *data_dir;
  float length_scale;
} SherpaOnnxOfflineTtsKittenModelConfig;

typedef struct SherpaOnnxOfflineTtsZipvoiceModelConfig {
  const char *tokens;
  const char *encoder;
  const char *decoder;
  const char *vocoder;
  const char *data_dir;
  const char *lexicon;
  float feat_scale;
  float t_shift;
  float target_rms;
  float guidance_scale;
} SherpaOnnxOfflineTtsZipvoiceModelConfig;

typedef struct SherpaOnnxOfflineTtsPocketModelConfig {
  const char *lm_flow;
  const char *lm_main;
  const char *encoder;
  const char *decoder;
  const char *text_conditioner;
  const char *vocab_json;
  const char *token_scores_json;
  int32_t voice_embedding_cache_capacity;
} SherpaOnnxOfflineTtsPocketModelConfig;

typedef struct SherpaOnnxOfflineTtsSupertonicModelConfig {
  const char *duration_predictor;
  const char *text_encoder;
  const char *vector_estimator;
  const char *vocoder;
  const char *tts_json;
  const char *unicode_indexer;
  const char *voice_style;
} SherpaOnnxOfflineTtsSupertonicModelConfig;

typedef struct SherpaOnnxOfflineTtsModelConfig {
  SherpaOnnxOfflineTtsVitsModelConfig vits;
  int32_t num_threads;
  int32_t debug;
  const char *provider;
  SherpaOnnxOfflineTtsMatchaModelConfig matcha;
  SherpaOnnxOfflineTtsKokoroModelConfig kokoro;
  SherpaOnnxOfflineTtsKittenModelConfig kitten;
  SherpaOnnxOfflineTtsZipvoiceModelConfig zipvoice;
  SherpaOnnxOfflineTtsPocketModelConfig pocket;
  SherpaOnnxOfflineTtsSupertonicModelConfig supertonic;
} SherpaOnnxOfflineTtsModelConfig;

typedef struct SherpaOnnxOfflineTtsConfig {
  SherpaOnnxOfflineTtsModelConfig model;
  const char *rule_fsts;
  int32_t max_num_sentences;
  const char *rule_fars;
  float silence_scale;
} SherpaOnnxOfflineTtsConfig;

typedef struct SherpaOnnxGeneratedAudio {
  const float *samples;
  int32_t n;
  int32_t sample_rate;
} SherpaOnnxGeneratedAudio;

typedef struct SherpaOnnxGenerationConfig {
  float silence_scale;
  float speed;
  int32_t sid;
  const float *reference_audio;
  int32_t reference_audio_len;
  int32_t reference_sample_rate;
  const char *reference_text;
  int32_t num_steps;
  const char *extra;
} SherpaOnnxGenerationConfig;

typedef struct SherpaOnnxOfflineTts SherpaOnnxOfflineTts;

#endif
