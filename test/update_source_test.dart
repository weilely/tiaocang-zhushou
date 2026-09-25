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

    test('arm64 设备遇到只有 armeabi 的包 → 不给包（别塞错架构）', () {
      final a = assets(['app-armeabi-v7a.apk']);
      // 全是带架构的包、却没一个匹配 → 返回 null，界面提示"没有适配你机型的包"；
      // 硬塞 armeabi 的包只会"下载成功、安装失败"
      expect(pickApkAssetForAbi(a, 'arm64-v8a'), isNull);
      // 有 arm64 时必须优先它
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

    test('认不出设备 ABI 时退到通用包；没有可用 apk 返回 null', () {
      final a = assets(['x-arm64.apk']);
      // ABI 未知时 wanted 为空 → 带架构的包也不算匹配，但也没有通用包 → null
      expect(pickApkAssetForAbi(a, ''), isNull);
      expect(pickApkAssetForAbi(assets(['app.apk']), ''), endsWith('app.apk'));
      expect(pickApkAssetForAbi(assets(['notes.txt']), 'arm64-v8a'), isNull);
      expect(pickApkAssetForAbi(null, 'arm64-v8a'), isNull);
    });

    test('只认 .apk，zip/tar.gz 不会被当成安装包', () {
      final a = assets(['v1.0.4.zip', 'v1.0.4.tar.gz', 'v1.0.4-arm64.apk']);
      expect(pickApkAssetForAbi(a, 'arm64-v8a'), endsWith('v1.0.4-arm64.apk'));
    });
  });

  group('「最新可安装版本」（只在值得的版本传附件时靠它）', () {
    UpdateInfo info(String v, {String? apk}) => UpdateInfo(
          latest: v,
          url: 'https://example.com/releases',
          source: 'Gitee',
          apkUrl: apk,
        );

    /// 与 checkUpdate 里同一套挑选逻辑
    UpdateInfo? newestWithApk(List<UpdateInfo> all) {
      final withApk = all.where((e) => e.hasApk).toList();
      if (withApk.isEmpty) return null;
      return withApk.reduce(
          (a, b) => isNewerVersion(b.latest, a.latest) ? b : a);
    }

    test('最新版没包、但上一版有包 → 应用内仍能升到那一版', () {
      final all = [
        info('1.0.9'), // 最新，没传附件
        info('1.0.8', apk: 'https://e/1.0.8-arm64.apk'),
        info('1.0.7', apk: 'https://e/1.0.7-arm64.apk'),
      ];
      final inst = newestWithApk(all)!;
      expect(inst.latest, '1.0.8', reason: '应挑最新的那个「带包」版本');
      expect(isNewerVersion(inst.latest, '1.0.5'), isTrue,
          reason: '比当前新，界面该给「下载并安装」');
    });

    test('最新版自己有包 → 可安装版本就是它', () {
      final all = [
        info('1.1.0', apk: 'https://e/1.1.0-arm64.apk'),
        info('1.0.8', apk: 'https://e/1.0.8-arm64.apk'),
      ];
      expect(newestWithApk(all)!.latest, '1.1.0');
    });

    test('一个带包的版本都没有 → 只能手动下载', () {
      expect(newestWithApk([info('1.0.9'), info('1.0.8')]), isNull);
    });

    test('带包的那版比当前还旧 → 不该提示可升级', () {
      final inst = newestWithApk([info('1.0.4', apk: 'https://e/x.apk')])!;
      // 当前已经是 1.0.5，这个带包的 1.0.4 更旧 → 界面应走"没有可安装的新版"
      expect(isNewerVersion(inst.latest, '1.0.5'), isFalse);
    });
  });

  group('发行版 JSON → UpdateInfo（含更新条目与日期）', () {
    Map<String, Object?> release({
      String tag = 'v1.1.8',
      String? body = '## 新功能\n- 检查更新看得到更新条目了',
      String? published = '2026-09-25T10:00:00Z',
      List<String> assets = const [],
    }) =>
        {
          'tag_name': tag,
          'html_url': 'https://example.com/releases/tag/$tag',
          'body': body,
          'published_at': published,
          'assets': [
            for (final n in assets)
              {'name': n, 'browser_download_url': 'https://e/$n'},
          ],
        };

    test('GitHub：版本号/发行说明/日期/附件都捞到', () {
      final info = githubReleaseToInfo(
        release(assets: ['tiaocang-zhushou-v1.1.8-arm64-v8a.apk']),
        'weilely/tiaocang-zhushou',
        'arm64-v8a',
      )!;
      expect(info.latest, '1.1.8');
      expect(info.source, 'GitHub');
      expect(info.hasNotes, isTrue);
      expect(info.notes, contains('更新条目'));
      expect(info.publishedAt, isNotNull);
      expect(info.hasApk, isTrue);
      expect(info.url, contains('releases/tag/v1.1.8'));
    });

    test('Gitee：字段名一样，也能解析', () {
      final info = giteeReleaseToInfo(
        release(tag: 'v1.1.9', assets: ['x-arm64-v8a.apk']),
        'weilely/tiaocang-zhushou',
        'arm64-v8a',
      )!;
      expect(info.source, 'Gitee');
      expect(info.latest, '1.1.9');
      expect(info.hasApk, isTrue);
    });

    test('没有 body / 日期解析不出来 → 不炸，只是没条目', () {
      final info = githubReleaseToInfo(
        release(body: '', published: '不是日期'),
        'weilely/tiaocang-zhushou',
        'arm64-v8a',
      )!;
      expect(info.hasNotes, isFalse);
      expect(info.publishedAt, isNull);
    });

    test('tag 不带版本号 → 跳过（返回 null）', () {
      expect(
        githubReleaseToInfo(
            release(tag: 'nightly'), 'weilely/tiaocang-zhushou', ''),
        isNull,
      );
      expect(tagToInfo('abc', url: 'u', source: 'GitHub'), isNull);
    });

    test('tags 接口的条目：只有版本号和页面地址', () {
      final info =
          tagToInfo('v1.1.8', url: 'https://e/releases', source: 'Gitee')!;
      expect(info.latest, '1.1.8');
      expect(info.hasNotes, isFalse);
      expect(info.hasApk, isFalse);
    });
  });

  group('更新条目合并与筛选（更新页面就用这两个）', () {
    UpdateInfo info(String v, {String? notes, String? apk}) => UpdateInfo(
          latest: v,
          url: 'https://e/$v',
          source: 'Gitee',
          notes: notes,
          apkUrl: apk,
        );

    test('同版本去重：留带发行说明的那条（不然更新条目会是空的）', () {
      final merged = mergeReleases([
        info('1.1.8'), // GitHub 只有 tag
        info('1.1.8', notes: '修复了滚动问题'), // Gitee 建了发行版
      ]);
      expect(merged.length, 1);
      expect(merged.single.hasNotes, isTrue);
      expect(merged.single.notes, contains('滚动'));
    });

    test('都有说明时留带安装包的那条', () {
      final merged = mergeReleases([
        info('1.1.8', notes: 'A'),
        info('1.1.8', notes: 'B', apk: 'https://e/x.apk'),
      ]);
      expect(merged.single.hasApk, isTrue);
    });

    test('新→旧排序（不是按返回顺序）', () {
      final merged = mergeReleases([
        info('1.0.9'),
        info('1.10.0'),
        info('1.1.0'),
      ]);
      expect(merged.map((e) => e.latest).toList(), ['1.10.0', '1.1.0', '1.0.9']);
    });

    test('releasesNewerThan：只留比当前新的，顺序不变', () {
      final all = mergeReleases([
        info('1.1.9', notes: '最新'),
        info('1.1.8', notes: '次新'),
        info('1.1.7', notes: '当前这版'),
        info('1.1.6', notes: '老版本'),
      ]);
      final newer = releasesNewerThan(all, '1.1.7');
      expect(newer.map((e) => e.latest).toList(), ['1.1.9', '1.1.8']);
    });

    test('已是最新时，更新条目为空', () {
      final all = mergeReleases([info('1.1.7'), info('1.1.6')]);
      expect(releasesNewerThan(all, '1.1.7'), isEmpty);
    });
  });
}
