import 'package:flutter_test/flutter_test.dart';
import 'package:invest_tracker/data/update_source.dart';

/// 版本号比较与「从 tag 列表挑最新」—— 在线检查更新的判定核心
void main() {
  group('parseVersion', () {
    test('各种前缀都能解析', () {
      expect(parseVersion('1.0.2'), [1, 0, 2]);
      expect(parseVersion('v1.0.2'), [1, 0, 2]);
      expect(parseVersion('release-1.2.3'), [1, 2, 3]);
      expect(parseVersion('  v2.10.0  '), [2, 10, 0]);
    });

    test('解析不出来返回 null', () {
      expect(parseVersion(''), isNull);
      expect(parseVersion('abc'), isNull);
      expect(parseVersion('1.0'), isNull);
    });
  });

  group('isNewerVersion', () {
    test('逐段比较，不是字符串比较（1.10 > 1.9）', () {
      expect(isNewerVersion('1.10.0', '1.9.0'), isTrue);
      expect(isNewerVersion('1.9.0', '1.10.0'), isFalse);
    });

    test('patch / minor / major 递增都算新', () {
      expect(isNewerVersion('1.0.2', '1.0.1'), isTrue);
      expect(isNewerVersion('1.1.0', '1.0.9'), isTrue);
      expect(isNewerVersion('2.0.0', '1.99.99'), isTrue);
    });

    test('相同或更旧返回 false', () {
      expect(isNewerVersion('1.0.1', '1.0.1'), isFalse);
      expect(isNewerVersion('1.0.0', '1.0.1'), isFalse);
    });

    test('无法解析时不冒进（返回 false，不提示更新）', () {
      expect(isNewerVersion('abc', '1.0.1'), isFalse);
      expect(isNewerVersion('1.0.2', 'xyz'), isFalse);
    });
  });

  group('pickNewest', () {
    test('从乱序 tag 里挑出版本最大的', () {
      expect(
        pickNewest(['v1.0.0', 'v1.2.0', 'v1.10.1', 'v1.3.4', 'v1.9.9']),
        '1.10.1',
      );
    });

    test('忽略不像版本号的 tag，返回规范化的 X.Y.Z', () {
      expect(pickNewest(['nightly', 'v1.0.1', 'backup']), '1.0.1');
    });

    test('一个合法版本都没有 → null', () {
      expect(pickNewest([]), isNull);
      expect(pickNewest(['abc', 'nightly']), isNull);
    });
  });

  group('UpdateSource', () {
    test('主仓库地址写死在代码里，便于核对', () {
      expect(UpdateSource.githubRepo, contains('/'));
    });
  });

  group('候选合并：release 旧、tag 新时要取 tag', () {
    test('实测场景 —— v1.0.0 有 Release、v1.0.1 只有 tag', () {
      // 这就是线上真实情况：只发 tag 没建 Release，
      // 若只看 releases/latest 会把「最新版本」显示成 v1.0.0
      final fromRelease = '1.0.0';
      final fromTags = pickNewest(['v1.0.0', 'v1.0.1']);
      expect(fromTags, '1.0.1');
      expect(isNewerVersion(fromTags!, fromRelease), isTrue,
          reason: 'tag 里的 1.0.1 比 release 的 1.0.0 新，应当取它');
    });
  });

  group('按设备 ABI 挑 APK 附件', () {
    List<Map<String, Object?>> assets(List<String> names) => [
          for (final n in names)
            {
              'name': n,
              'browser_download_url': 'https://example.com/$n',
            },
        ];

    test('三个架构都在时，各挑各的（arm64 不能挑到 armeabi-v7a）', () {
      final a = assets([
        'tiaocang-zhushou-v1.0.4-arm64.apk',
        'tiaocang-zhushou-v1.0.4-armeabi-v7a.apk',
        'tiaocang-zhushou-v1.0.4-x86_64.apk',
      ]);
      expect(pickApkAssetForAbi(a, 'arm64-v8a'),
          endsWith('tiaocang-zhushou-v1.0.4-arm64.apk'));
      expect(pickApkAssetForAbi(a, 'armeabi-v7a'),
          endsWith('tiaocang-zhushou-v1.0.4-armeabi-v7a.apk'));
      expect(pickApkAssetForAbi(a, 'x86_64'),
          endsWith('tiaocang-zhushou-v1.0.4-x86_64.apk'));
    });

    test('arm64 设备不会挑到 armeabi 的包', () {
      final a = assets(['app-armeabi-v7a.apk']);
      // 没有 arm64 的包 → 退回「任意 apk」，但绝不能声称匹配
      expect(pickApkAssetForAbi(a, 'arm64-v8a'), endsWith('app-armeabi-v7a.apk'));
      // 关键是上面那次是**兜底**，不是"匹配"；有 arm64 时必须优先它
      final b = assets(['app-armeabi-v7a.apk', 'app-arm64-v8a.apk']);
      expect(pickApkAssetForAbi(b, 'arm64-v8a'), endsWith('app-arm64-v8a.apk'));
    });

    test('有通用包（名字不带架构）时，没匹配到就优先通用包', () {
      final a = assets([
        'tiaocang-zhushou-v1.0.4.apk',
        'tiaocang-zhushou-v1.0.4-x86_64.apk',
      ]);
      expect(pickApkAssetForAbi(a, 'arm64-v8a'),
          endsWith('tiaocang-zhushou-v1.0.4.apk'));
    });

    test('认不出设备 ABI 时退到任意 apk；没有 apk 返回 null', () {
      final a = assets(['x-arm64.apk']);
      expect(pickApkAssetForAbi(a, ''), endsWith('x-arm64.apk'));
      expect(pickApkAssetForAbi(assets(['notes.txt']), 'arm64-v8a'), isNull);
      expect(pickApkAssetForAbi(null, 'arm64-v8a'), isNull);
    });

    test('只认 .apk，zip/tar.gz 不会被当成安装包', () {
      final a = assets(['v1.0.4.zip', 'v1.0.4.tar.gz', 'v1.0.4-arm64.apk']);
      expect(pickApkAssetForAbi(a, 'arm64-v8a'), endsWith('v1.0.4-arm64.apk'));
    });
  });
}
