import 'package:pinyin/pinyin.dart';

/// 全角字母/数字 → 半角（股票名里存在「鲁 泰Ａ」这种全角写法）
String _toHalfWidth(String s) {
  final buf = StringBuffer();
  for (final r in s.runes) {
    if (r >= 0xFF01 && r <= 0xFF5E) {
      buf.writeCharCode(r - 0xFEE0); // 全角 ASCII → 半角
    } else if (r == 0x3000) {
      buf.write(' '); // 全角空格
    } else {
      buf.writeCharCode(r);
    }
  }
  return buf.toString();
}

/// 去掉拼音库在汉字/非汉字交界处插入的空格，以及其它分隔符
final RegExp _separators = RegExp(r'[\s,\-_·。、（）()]+');

/// 名称的拼音首字母缩写（大写）。
///
/// - `贵州茅台` → `GZMT`
/// - `新 和 成` → `XHC`（名称里的空格会被忽略）
/// - `TCL科技` → `TCLKJ`（拉丁字母原样保留）
/// - `沪深300ETF华泰柏瑞` → `HS300ETFHTBR`
String pinyinInitials(String name) {
  final cleaned = _toHalfWidth(name).trim();
  if (cleaned.isEmpty) return '';
  final raw = PinyinHelper.getShortPinyin(cleaned);
  return raw.replaceAll(_separators, '').toUpperCase();
}

/// 名称的全拼（无分隔、小写）。转换失败返回空串，不抛异常。
///
/// - `贵州茅台` → `guizhoumaotai`
String fullPinyinOf(String name) {
  final cleaned = _toHalfWidth(name).trim();
  if (cleaned.isEmpty) return '';
  try {
    return PinyinHelper.getPinyin(cleaned, separator: '').replaceAll(_separators, '').toLowerCase();
  } catch (_) {
    // 字典里缺字时不要中断整批导入
    return '';
  }
}
