import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image_picker/image_picker.dart';

import '../logic/receipt_parser.dart';

/// 一次识别的结果：识别到的文字行 + 失败原因（成功时为 null）
///
/// 刻意不往外抛异常：OCR 走的是平台通道，失败了界面还能用手工录入接着干，
/// 不该让一次识别失败把整条导入流程（甚至 App）带走。
class OcrResult {
  final List<OcrLine> lines;
  final String? error;

  const OcrResult(this.lines, [this.error]);

  bool get ok => error == null;

  /// 识别到了内容（判断"是不是白图"用）
  bool get hasText => lines.isNotEmpty;
}

/// 本地 OCR（Google ML Kit 中文文字识别）——不联网、不上传
///
/// 中文模型由 `android/app/build.gradle.kts` 里的
/// `com.google.mlkit:text-recognition-chinese` 打进 release 包；
/// 插件默认只把拉丁模型 implementation 进包，少了那条依赖就会在
/// 「选完图识别中文」这一步让原生库崩掉（App 退出）。
class OcrSource {
  TextRecognizer? _recognizer;

  TextRecognizer get _engine =>
      _recognizer ??= TextRecognizer(script: TextRecognitionScript.chinese);

  /// 让用户拍照或从相册选一张图
  Future<String?> pickImage({required bool fromCamera}) async {
    final picker = ImagePicker();
    final file = await picker.pickImage(
      source: fromCamera ? ImageSource.camera : ImageSource.gallery,
      // 先压再识别：长边太大对识别没帮助，只会更慢、更吃内存
      maxWidth: 2000,
      maxHeight: 2000,
      imageQuality: 85,
    );
    return file?.path;
  }

  /// 识别图片里的文字行（含外接框，供版面还原用）
  Future<OcrResult> recognize(String imagePath) async {
    try {
      final input = InputImage.fromFilePath(imagePath);
      final result = await _engine.processImage(input);

      final out = <OcrLine>[];
      // 带上文本块序号：同一张"持仓卡片"的文字常常落在同一个 block 里，
      // 解析时用它分段比纯几何切分稳得多（见 logic/receipt_parser.dart）
      for (var bi = 0; bi < result.blocks.length; bi++) {
        final block = result.blocks[bi];
        for (final line in block.lines) {
          final b = line.boundingBox;
          final text = line.text.trim();
          if (text.isEmpty) continue;
          out.add(OcrLine(
            text: text,
            left: b.left,
            top: b.top,
            right: b.right,
            bottom: b.bottom,
            block: bi,
          ));
        }
      }
      return OcrResult(out);
    } catch (e) {
      // 引擎可能已被关掉或初始化失败：丢掉它，下次重建
      _reset();
      return OcrResult(const [], '识别失败：$e');
    }
  }

  void _reset() {
    try {
      _recognizer?.close();
    } catch (_) {
      // close 再失败也无所谓，反正要丢掉
    }
    _recognizer = null;
  }

  void dispose() => _reset();
}
