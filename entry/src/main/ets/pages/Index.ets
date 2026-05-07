import { webSocket } from '@kit.NetworkKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { BusinessError, pasteboard } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { audio } from '@kit.AudioKit';
import { fileIo, picker } from '@kit.CoreFileKit';
import mp3Decoder from 'libmp3_decoder.so';
// ===== 类型定义 =====
interface VoiceItem {
  label: string;
  value: string;
}

// ===== 常量 =====
const TRUSTED_CLIENT_TOKEN: string = '6A5AA1D4EAFF4E9FB37E23D68491D6F4';
const WIN_EPOCH: number = 11644473600;
const SEC_MS_GEC_VERSION: string = '1-143.0.3650.75';
const WSS_BASE: string = 'wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1';

const VOICES: VoiceItem[] = [
  { label: '晓晓 (女)', value: 'zh-CN-XiaoxiaoNeural' },
  { label: '云希 (男)', value: 'zh-CN-YunxiNeural' },
  { label: '云扬 (男-新闻)', value: 'zh-CN-YunyangNeural' },
  { label: 'Jenny (英女)', value: 'en-US-JennyNeural' },
];

// ===== SHA256 =====
async function sha256(text: string): Promise<string> {
  try {
    const encoder: util.TextEncoder = new util.TextEncoder();
    const data: Uint8Array = encoder.encodeInto(text);
    const md = cryptoFramework.createMd('SHA256');
    await md.update({ data: data });
    const hash = await md.digest();
    const hex: string[] = [];
    for (const b of hash.data) {
      hex.push(b.toString(16).padStart(2, '0'));
    }
    return hex.join('').toUpperCase();
  } catch (e) {
    console.error('[sha256] failed: ' + (e as Error).message);
    return '';
  }
}

// ===== UUID =====
function uuid(): string {
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (c: string): string => {
    const r: number = Math.random() * 16 | 0;
    return (c === 'x' ? r : (r & 0x3 | 0x8)).toString(16);
  });
}

// ===== 日期格式；匹配 Python strftime('%a %d %b %Y %H:%M:%S GMT') =====
function dateToString(): string {
  const d: Date = new Date();
  const days: string[] = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
  const months: string[] = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  const pad = (n: number): string => n.toString().padStart(2, '0');
  return days[d.getUTCDay()] + ' '
    + pad(d.getUTCDate()) + ' '
    + months[d.getUTCMonth()] + ' '
    + d.getUTCFullYear() + ' '
    + pad(d.getUTCHours()) + ':'
    + pad(d.getUTCMinutes()) + ':'
    + pad(d.getUTCSeconds()) + ' GMT';
}



// ===== 主组件 =====
@Entry
@Component
struct Index {
  @State text: string = '大家好，这是一个语音测试。'
  @State voiceIndex: number = 0
  @State status: string = ''
  @State isPlaying: boolean = false
  @State logs: string[] = []

  private audioRenderer: audio.AudioRenderer | null = null

  private ws: webSocket.WebSocket | null = null
  private audioChunks: Uint8Array[] = []
  private audioSize: number = 0
  private startTime: number = 0
  private cancelled: boolean = false

  aboutToDisappear(): void {
    this.doStop();
  }

  log(msg: string, isError?: boolean): void {
    const t: string = new Date().toLocaleTimeString();
    const prefix: string = isError ? '❌ ' : '';
    const line: string = prefix + '[' + t + '] ' + msg;
    this.logs.push(line);
    if (this.logs.length > 200) {
      this.logs.splice(0, 50);
    }
    if (isError) {
      console.error('[TTS] ' + msg);
    } else {
      console.info('[TTS] ' + msg);
    }
    this.logs = [...this.logs];
  }

  copyLogs(): void {
    const text: string = this.logs.join('\n');
    if (!text) {
      this.status = '日志为空';
      return;
    }
    try {
      const pb = pasteboard.getSystemPasteboard();
      const pasteData = pasteboard.createPlainTextData(text);
      pb.setData(pasteData);
      this.status = '已复制 ' + this.logs.length + ' 行';
    } catch (_e) {
      this.status = '复制失败';
    }
  }

  clearLogs(): void {
    this.logs = [];
  }

  doStop(): void {
    this.cancelled = true;
    if (this.ws) {
      try { this.ws.close(); } catch (_e) { }
      this.ws = null;
    }
    // 停止 AudioRenderer
    if (this.audioRenderer) {
      try {
        this.audioRenderer.stop();
        this.audioRenderer.release();
      } catch (_e) { }
      this.audioRenderer = null;
    }
    this.audioChunks = [];
    this.audioSize = 0;
    this.isPlaying = false;
    this.status = '已停止';
    this.log('已停止');
  }

  async doSynthesize(): Promise<void> {
    const text: string = this.text.trim();
    if (!text) {
      this.status = '请输入文字';
      return;
    }
    if (this.isPlaying) {
      this.doStop();
      return;
    }

    this.logs = [];
    this.audioChunks = [];
    this.audioSize = 0;
    this.cancelled = false;
    this.startTime = Date.now();
    this.isPlaying = true;
    this.status = '连接中...';

    const voice: string = VOICES[this.voiceIndex].value;
    const connectionId: string = uuid();
    const requestId: string = uuid();

    try {
      // --- 生成 GEC Token ---
      const now: number = Math.floor(Date.now() / 1000);
      const ticks: number = (now + WIN_EPOCH) * 10000000;
      const rounded: number = Math.round(ticks / 3000000000) * 3000000000;
      const gec: string = rounded.toString() + TRUSTED_CLIENT_TOKEN;
      const gecToken: string = await sha256(gec);
      this.log('GEC token: ' + gecToken.substring(0, 16) + '...');

      const muid: string = uuid().replace(/-/g, '').toUpperCase();
      const wssUrl: string = WSS_BASE + '?TrustedClientToken=' + TRUSTED_CLIENT_TOKEN
        + '&ConnectionId=' + connectionId
        + '&Sec-MS-GEC=' + gecToken
        + '&Sec-MS-GEC-Version=' + encodeURIComponent(SEC_MS_GEC_VERSION);

      // --- 连接 WebSocket ---
      const ws = webSocket.createWebSocket();
      this.ws = ws;

      ws.on('open', (): void => {
        this.log('✓ WS 已连接');
        this.status = '发送配置...';

        // 1. Config 消息
        const configBody: string = '{"context":{"synthesis":{"audio":{"metadataoptions":{"sentenceBoundaryEnabled":false,"wordBoundaryEnabled":false},"outputFormat":"audio-24khz-48kbitrate-mono-mp3"}}}}';
        const configMsg: string = 'Content-Type:application/json; charset=utf-8\r\nPath:speech.config\r\n\r\n' + configBody;
        ws.send(configMsg);
        this.log('✓ Config 已发送 (' + configMsg.length + ' B)');

        // 2. 200ms 后发 SSML
        setTimeout((): void => {
          if (this.cancelled) {
            return;
          }
          const dateStr: string = dateToString() + 'Z';
          const lang: string = voice.startsWith('en') ? 'en-US' : 'zh-CN';
          const ssmlBody: string = '<speak version=\'1.0\' xmlns=\'http://www.w3.org/2001/10/synthesis\' xml:lang=\'' + lang + '\'>'
            + '<voice name=\'' + voice + '\'>' + this.escapeXml(text) + '</voice></speak>';
          const ssmlMsg: string = 'X-RequestId:' + requestId + '\r\n'
            + 'Content-Type:application/ssml+xml\r\n'
            + 'X-Timestamp:' + dateStr + '\r\n'
            + 'Path:ssml\r\n\r\n'
            + ssmlBody;
          this.log('SSML 已发送 (' + ssmlMsg.length + ' B, lang=' + lang + ')');
          this.status = '等待音频...';
          ws.send(ssmlMsg);
        }, 200);
      });

      ws.on('message', (_err: BusinessError, data: string | ArrayBuffer): void => {
        if (this.cancelled) {
          return;
        }
        if (typeof data === 'string') {
          const msg: string = data as string;
          if (msg.indexOf('turn.start') >= 0) {
            this.log('✓ turn.start 收到');
          } else if (msg.indexOf('turn.end') >= 0) {
            this.log('✓ turn.end — 音频传输完成');
            this.finishPlayback();
          } else if (msg.indexOf('Path:response') >= 0) {
            this.log('✓ response 收到');
          } else if (msg.indexOf('turn.start') === -1) {
            this.log('收到文本: ' + msg.substring(0, 80));
          }
        } else {
          this.parseAudio(data as ArrayBuffer);
        }
      });

      ws.on('close', (err: BusinessError | undefined, _result?: object): void => {
        if (err) {
          this.log('WS 关闭: code=' + err.code + ' msg=' + err.message, true);
          if (!this.cancelled && err.code !== 1000) {
            this.status = '连接关闭: ' + err.code;
          }
        } else {
          this.log('WS 已关闭', true);
          this.status = '连接关闭';
        }
        this.isPlaying = false;
        this.ws = null;
      });

      ws.on('error', (err: BusinessError): void => {
        this.log('WS 错误: ' + err.message, true);
        this.status = 'WS 错误';
        this.isPlaying = false;
      });

      // 连接
      this.log('连接中...');
      ws.connect(wssUrl, {
        header: {
          'Origin': 'chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold',
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36 Edg/143.0.0.0',
          'Cookie': 'muid=' + muid,
          'Pragma': 'no-cache',
          'Cache-Control': 'no-cache',
          'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
        }
      });

    } catch (e) {
      const err: BusinessError = e as BusinessError;
      this.log('异常: ' + err.message, true);
      this.status = '错误: ' + err.message;
      this.isPlaying = false;
    }
  }

  parseAudio(data: ArrayBuffer): void {
    try {
      const bytes: Uint8Array = new Uint8Array(data);
      if (bytes.length < 2) {
        return;
      }
      // Edge TTS 二进制协议：前2字节=header总长度（大端，含自身），
      // header 后面跟 \r\n（0x0D 0x0A）分隔符，然后才是音频数据
      const headerLen: number = (bytes[0] << 8) | bytes[1];
      const audioStart: number = headerLen + 2; // +2 跳过 header 后的 CRLF
      if (audioStart >= bytes.length) {
        // 只有 header，没有音频数据
        return;
      }
      const audioData: Uint8Array = bytes.slice(audioStart);
      this.audioChunks.push(audioData);
      this.audioSize += audioData.length;
      const elapsed: string = ((Date.now() - this.startTime) / 1000).toFixed(1);
      this.log('音频块: ' + audioData.length + ' B (累计 ' + (this.audioSize / 1024).toFixed(1) + ' KB, ' + elapsed + 's)');
      this.status = '接收中 ' + (this.audioSize / 1024).toFixed(1) + ' KB';
    } catch (_e) {
      this.log('解析音频块失败', true);
    }
  }

  async finishPlayback(): Promise<void> {
    if (this.audioChunks.length === 0) {
      this.log('没有收到音频数据', true);
      this.status = '没有音频数据';
      this.isPlaying = false;
      return;
    }

    try {
      // 合并音频
      const totalLen: number = this.audioChunks.reduce((s: number, c: Uint8Array): number => s + c.length, 0);
      const merged: Uint8Array = new Uint8Array(totalLen);
      let offset: number = 0;
      for (const chunk of this.audioChunks) {
        merged.set(chunk, offset);
        offset += chunk.length;
      }
      this.audioChunks = [];
      this.log('音频合并完成: ' + (totalLen / 1024).toFixed(1) + ' KB');

      // 每个 chunk 的 parseAudio 已正确跳过 header + \r\n，merged 直接就是干净 MP3 数据
      const writeBuf: ArrayBuffer = merged.buffer as ArrayBuffer;

      // 写入临时文件
      this.status = '正在播放...';
      try {
        const sandboxDir: string = getContext().filesDir;

        // 1. 保存原始 MP3（调试备份）
        const mp3Path: string = sandboxDir + '/tts_audio.mp3';
        const file: fileIo.File = fileIo.openSync(mp3Path, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
        fileIo.writeSync(file.fd, writeBuf);
        fileIo.closeSync(file.fd);
        this.log('MP3 已保存: ' + mp3Path + ' (' + writeBuf.byteLength + ' 字节)');

        // 2. 原生解码 MP3 → WAV（C++ 端解码并直接写文件）
        const mp3Uint8: Uint8Array = new Uint8Array(writeBuf);
        const wavPath: string = sandboxDir + '/tts_audio.wav';
        this.log('正在解码 MP3 → WAV...');
        try {
          mp3Decoder.decodeMp3ToWav(mp3Uint8, wavPath);
          this.log('WAV 解码写入成功: ' + wavPath);
        } catch (e) {
          this.log('解码失败: ' + (e as Error).message, true);
          this.status = '解码失败';
          this.isPlaying = false;
          return;
        }

        // 3. 原生 AudioRenderer 直接播放 PCM（跳过 WebView，无 autoplay 限制）
        try {
          const wavStat = fileIo.statSync(wavPath);
          const wavBuf: ArrayBuffer = new ArrayBuffer(wavStat.size);
          const wavFile: fileIo.File = fileIo.openSync(wavPath, fileIo.OpenMode.READ_ONLY);
          fileIo.readSync(wavFile.fd, wavBuf);
          fileIo.closeSync(wavFile.fd);
          const wavBytes: Uint8Array = new Uint8Array(wavBuf);
          const pcmData: Uint8Array = new Uint8Array(wavBytes.slice(44));
          this.log('PCM \u6570\u636E: ' + pcmData.length + ' \u5B57\u8282');

          const renderer: audio.AudioRenderer = await new Promise<audio.AudioRenderer>(
            (resolve: (value: audio.AudioRenderer) => void, reject: (reason?: Error) => void): void => {
              audio.createAudioRenderer({
                streamInfo: {
                  samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_24000,
                  channels: audio.AudioChannel.CHANNEL_1,
                  sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
                  encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
                },
                rendererInfo: {
                  content: audio.ContentType.CONTENT_TYPE_SPEECH,
                  usage: audio.StreamUsage.STREAM_USAGE_MEDIA,
                  rendererFlags: 0
                }
              }, (err: BusinessError, data: audio.AudioRenderer): void => {
                if (err) { reject(new Error(err.message)); }
                else { resolve(data); }
              });
            });
          this.audioRenderer = renderer;
          this.log('AudioRenderer \u5DF2\u521B\u5EFA');

          await renderer.start();
          this.log('AudioRenderer \u5DF2\u542F\u52A8');
          this.status = '\u64AD\u653E\u4E2D...';

          const written: number = await renderer.write(pcmData.buffer as ArrayBuffer);
          this.log('\u64AD\u653E\u5B8C\u6210: ' + written + ' \u5B57\u8282\u5199\u5165');
          this.status = '\u64AD\u653E\u5B8C\u6210';

          renderer.stop();
          renderer.release();
          this.audioRenderer = null;


        } catch (e) {
          if (this.audioRenderer) {
            try { this.audioRenderer.release(); } catch (_e) { }
            this.audioRenderer = null;
          }
          if (this.cancelled) {
            this.log('\u64AD\u653E\u5DF2\u505C\u6B62');
            this.status = '\u5DF2\u505C\u6B62';
          } else {
            this.log('\u64AD\u653E\u5931\u8D25: ' + (e as Error).message, true);
            this.status = '\u64AD\u653E\u5931\u8D25';
          }
        }

        // 关闭 WS 并重置播放状态，允许立即再次朗读
        if (this.ws) {
          try { this.ws.close(); } catch (_e) { }
          this.ws = null;
        }
        this.isPlaying = false;
      } catch (e) {
        const we: BusinessError = e as BusinessError;
        this.log('写文件/播放失败: ' + we.message, true);
        this.status = '播放失败';
        this.isPlaying = false;
      }
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      this.log('播放失败: ' + err.message, true);
      this.status = '播放失败';
      this.isPlaying = false;
    }
  }

  // 已剥离 CRLF 前缀，磁盘文件为合法 MP3

  async saveToDownloads(): Promise<void> {
    try {
      // 导出 WAV（解码后的文件，用于在其他设备上测试）
      const filePath: string = getContext().filesDir + '/tts_audio.wav';
      const stat = fileIo.statSync(filePath);
      const buf: ArrayBuffer = new ArrayBuffer(stat.size);
      const srcFile: fileIo.File = fileIo.openSync(filePath, fileIo.OpenMode.READ_ONLY);
      fileIo.readSync(srcFile.fd, buf);
      fileIo.closeSync(srcFile.fd);
      // 弹出保存对话框
      const documentPicker = new picker.DocumentViewPicker(getContext());
      const uris: string[] = await documentPicker.save({ newFileNames: ['tts_audio.wav'] });
      if (uris && uris.length > 0) {
        const destFile: fileIo.File = fileIo.openSync(uris[0], fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
        fileIo.writeSync(destFile.fd, buf);
        fileIo.closeSync(destFile.fd);
        this.log('WAV 已保存到下载目录');
        this.status = 'WAV 已保存到下载';
      }
    } catch (e) {
      const se: BusinessError = e as BusinessError;
      this.log('保存失败: ' + se.message, true);
      this.status = '保存失败';
    }
  }

  escapeXml(str: string): string {
    return str.replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&apos;');
  }

  build() {
    Column() {
      Text('语音合成')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor('#1c1c1e')
        .fontFamily('HarmonyOS Sans')
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ top: 14, bottom: 10 })

      Scroll() {
        Column() {
          // 文本框
          TextArea({ placeholder: '输入要朗读的文字...', text: this.text })
            .height(90)
            .fontSize(15)
            .fontColor('#1c1c1e')
            .placeholderColor('#86868b')
            .padding(10)
            .borderRadius(8)
            .border({ width: 1, color: '#d2d2d7' })
            .backgroundColor('#ffffff')
            .onChange((v: string): void => { this.text = v; })

          // 语音选择
          Text('语音角色')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor('#1c1c1e')
            .width('100%')
            .margin({ top: 10, bottom: 4 })

          Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
            ForEach(VOICES, (item: VoiceItem, idx: number): void => {
              Text(item.label)
                .fontSize(12)
                .fontColor(this.voiceIndex === idx ? '#ffffff' : '#1c1c1e')
                .backgroundColor(this.voiceIndex === idx ? '#007aff' : '#e8e8ed')
                .borderRadius(6)
                .padding({ top: 6, bottom: 6, left: 10, right: 10 })
                .margin({ top: 4, right: 6 })
                .onClick((): void => { this.voiceIndex = idx; })
            }, (_item: VoiceItem, idx: number): string => idx.toString())
          }
          .width('100%')
          .padding({ top: 4 })

          // 按钮行
          Row() {
            Button('朗读')
              .height(40)
              .backgroundColor('#007aff')
              .borderRadius(8)
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .layoutWeight(1)
              .onClick((): void => {
                if (!this.isPlaying) {
                  this.doSynthesize();
                }
              })

            Button('停止')
              .height(40)
              .backgroundColor('#ff3b30')
              .borderRadius(8)
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .layoutWeight(1)
              .margin({ left: 8 })
              .enabled(this.isPlaying)
              .onClick((): void => { this.doStop(); })

            Button('导出')
              .height(40)
              .backgroundColor('#86868b')
              .borderRadius(8)
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .layoutWeight(1)
              .margin({ left: 8 })
              .onClick((): void => { this.saveToDownloads(); })
          }
          .width('100%')
          .margin({ top: 12 })
          .justifyContent(FlexAlign.Center)

          // 状态
          Text(this.status)
            .fontSize(13)
            .fontColor('#86868b')
            .width('100%')
            .textAlign(TextAlign.Center)
            .padding({ top: 8 })
            .lineHeight(18)

        }
        .padding({ left: 14, right: 14 })
      }
      .layoutWeight(0)

      Divider().color('#d2d2d7').margin({ top: 6 })

      // 日志工具栏
      Row() {
        Text('调试日志')
          .fontSize(12)
          .fontColor('#86868b')
        Blank()
        Text('复制')
          .fontSize(11)
          .fontColor('#34c759')
          .onClick((): void => { this.copyLogs(); })
        Text('  ·  ')
          .fontSize(11)
          .fontColor('#d2d2d7')
        Text('清空')
          .fontSize(11)
          .fontColor('#007aff')
          .onClick((): void => { this.clearLogs(); })
      }
      .width('100%')
      .padding({ left: 14, right: 14, top: 6, bottom: 4 })

      // 日志列表
      List({ space: 2 }) {
        ForEach(this.logs, (item: string): void => {
          ListItem() {
            Text(item)
              .fontSize(10)
              .fontColor('#1c1c1e')
              .width('100%')
              .padding({ left: 10, right: 10, top: 2, bottom: 2 })
              .lineHeight(16)
          }
        }, (_item: string, index: number): string => index.toString())
      }
      .width('100%')
      .height('100%')
      .layoutWeight(1)
      .backgroundColor('#fafafa')
      .listDirection(Axis.Vertical)

    }
    .width('100%')
    .height('100%')
    .backgroundColor('#f5f5f7')
    .expandSafeArea()
  }
}
