import 'db.dart';
import 'dca_models.dart';

/// 定投计划的读写（以扩展挂在 [AppDatabase] 上，不改动既有 DAO）
extension DcaRepo on AppDatabase {
  Future<List<DcaPlan>> dcaPlans({bool onlyEnabled = false}) async {
    final d = await database;
    final rows = await d.query(
      'dca_plans',
      where: onlyEnabled ? 'enabled = 1' : null,
      orderBy: 'enabled DESC, id ASC',
    );
    return rows.map(DcaPlan.fromMap).toList();
  }

  Future<List<DcaPlan>> dcaPlansForAsset(int assetId) async {
    final d = await database;
    final rows = await d.query('dca_plans',
        where: 'asset_id = ?', whereArgs: [assetId], orderBy: 'id ASC');
    return rows.map(DcaPlan.fromMap).toList();
  }

  Future<int> saveDcaPlan(DcaPlan p) async {
    final d = await database;
    if (p.id == null) {
      return d.insert('dca_plans', p.toMap()..remove('id'));
    }
    await d.update('dca_plans', p.toMap(), where: 'id = ?', whereArgs: [p.id]);
    return p.id!;
  }

  Future<void> deleteDcaPlan(int id) async {
    final d = await database;
    await d.delete('dca_plans', where: 'id = ?', whereArgs: [id]);
  }

  /// 推进「已补记到哪一期」。只允许前进，避免重复生成。
  Future<void> advanceDcaPlan(int id, DateTime lastRun) async {
    final d = await database;
    final ms = lastRun.millisecondsSinceEpoch;
    await d.rawUpdate(
      'UPDATE dca_plans SET last_run_date = ? WHERE id = ? AND last_run_date < ?',
      [ms, id, ms],
    );
  }

  Future<void> setDcaPlanEnabled(int id, bool enabled) async {
    final d = await database;
    await d.update('dca_plans', {'enabled': enabled ? 1 : 0},
        where: 'id = ?', whereArgs: [id]);
  }
}
