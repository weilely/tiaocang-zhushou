# 调仓助手（Invest Tracker）

一个自用的 Android 基金 / 股票投资跟踪应用，Flutter 编写，数据全部留在本机（SQLite），不依赖任何账号体系。

## 功能

- **持仓与记账**：买入 / 卖出 / 分红，份额与成本按净值核算，支持多账户
- **收益统计**：日历图（日 / 月 / 年）、趋势图（含基准对比）、资金流
- **调仓方案**：设目标占比，按实时行情算出买入 / 卖出份额，含偏离阈值
- **关注与净值**：自选基金净值批量刷新，历史净值留存
- **定投**：按周期自动扣款记账，支持到期自动执行
- **现金管理**：充值 / 提现 / 调整 / 收益，买卖分红自动联动现金流水
- **行情指标跑马灯**：大盘指数、行业指数、场内基金三类分通道取数，状态栏常驻上证
- **导入导出**：交易流水与持仓报表 CSV、完整备份 / 恢复、拍照导入持仓（中文 OCR）
- **安全**：可选生物识别解锁（指纹 / 人脸，中文提示）

## 构建

    # 环境：Flutter 3.47+ / Dart 3.13+、JDK 17、Android SDK
    flutter pub get
    flutter analyze          # 应为零错误零告警
    flutter test
    flutter build apk --release

产物：`build/app/outputs/flutter-apk/app-release.apk`

### 签名（可选）

发布包使用 `android/key.properties` + `android/app/*.jks` 签名，两者**已在 .gitignore 中排除**。
自行发布时按同样格式放一份即可；文件不存在时构建会自动退回 debug 签名，方便本机调试。

## 技术要点

- 行情：东财 push2 批量接口（指数 / ETF / 股票）+ 新浪大盘指数通道，三类指标各自容错与诊断
- OCR：ML Kit 中文模型（`text-recognition-chinese` 需在 gradle 里显式声明）
- 状态：`provider` + 单一 `AppState`，派生数据统一在 `_recompute()` 里重算
- 本地数据：`sqflite`，表结构迁移幂等

## 版本

v1.0.0　作者：吹角天明@MLB