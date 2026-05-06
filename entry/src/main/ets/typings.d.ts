// native module declaration for minimp3 MP3 decoder
declare module 'libmp3_decoder.so' {
  const mp3Decoder: {
    decodeMp3ToWav: (mp3Data: Uint8Array, outputPath: string) => boolean;
  };
  export default mp3Decoder;
}
