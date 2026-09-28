/// 应用版本号的**唯一显示来源**（应用内「关于」等处引用它）
///
/// Flutter 运行期读不到 pubspec.yaml，为此引 package_info_plus 又要多一个原生插件，
/// 不值当；这里用一个常量，并用 `tool/bump_version.ps1` 保证它与
/// `pubspec.yaml` 的 `version:` 永远一起改 —— 升版本请走那个脚本，别手改单个文件。
///
/// **例外（2026-09-28）**：用户要「出最新 APK、不发布」—— 那次是手动同步这两个文件
/// 到 1.1.9+19 的（脚本会顺带 commit+tag+push，不适合"只出包不发布"）。
/// 真正发布时仍走 `bump_version.ps1`。
library;

const String appVersion = '1.2.0';

/// 作者署名
const String appAuthor = '吹角天明@MLB';

/// 「关于」卡片里的整行文案
String get appVersionLine => '调仓助手 v$appVersion　$appAuthor';
