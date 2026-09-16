import 'package:flutter/material.dart';
import 'package:local_auth/local_auth.dart';
import 'package:local_auth_android/local_auth_android.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';

/// 生物识别解锁门
///
/// 开启「安全设置 → 生物识别解锁」后：冷启动、或从后台回来超过 30 秒，
/// 会盖一层遮罩，验证指纹 / 面容后才放行。设备不支持时自动放行，不会把人锁在外面。
class BiometricGate extends StatefulWidget {
  const BiometricGate({super.key, required this.child});

  final Widget child;

  @override
  State<BiometricGate> createState() => _BiometricGateState();
}

class _BiometricGateState extends State<BiometricGate>
    with WidgetsBindingObserver {
  final LocalAuthentication _auth = LocalAuthentication();
  DateTime? _leftAt;
  bool _asking = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _lockAndAsk());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (!mounted) return;
    if (s == AppLifecycleState.paused || s == AppLifecycleState.inactive) {
      _leftAt ??= DateTime.now();
      return;
    }
    if (s != AppLifecycleState.resumed) return;
    final at = _leftAt;
    _leftAt = null;
    final st = context.read<AppState>();
    if (!st.biometricEnabled || at == null) return;
    if (DateTime.now().difference(at).inSeconds >= 30) {
      st.setLocked(true);
      _ask();
    }
  }

  Future<void> _lockAndAsk() async {
    final st = context.read<AppState>();
    if (!st.biometricEnabled) return;
    st.setLocked(true);
    await _ask();
  }

  Future<void> _ask() async {
    if (_asking) return;
    _asking = true;
    final st = context.read<AppState>();
    try {
      final ok = await _auth.authenticate(
        localizedReason: '验证身份以解锁「调仓助手」',
        authMessages: const [
          AndroidAuthMessages(
            signInTitle: '解锁「调仓助手」',
            biometricHint: '请验证指纹或面容',
            biometricNotRecognized: '未识别，请重试',
            biometricSuccess: '验证成功',
            cancelButton: '取消',
            goToSettingsButton: '去设置',
            goToSettingsDescription: '本机还没有录入指纹或面容，请先在系统设置里添加',
          ),
        ],
        options: const AuthenticationOptions(
          stickyAuth: true,
          useErrorDialogs: true,
          biometricOnly: false,
        ),
      );
      if (ok) st.setLocked(false);
    } catch (_) {
      // 设备不支持 / 用户取消：保持锁定，可点「解锁」重试
    } finally {
      _asking = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final locked = context.watch<AppState>().locked;
    return Stack(
      children: [
        widget.child,
        if (locked)
          Positioned.fill(
            child: Material(
              color: const Color(0xFFF4F5F0),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.lock_outline,
                        size: 52, color: Color(0xFF1F3A5F)),
                    const SizedBox(height: 14),
                    const Text('已锁定',
                        style: TextStyle(
                            fontSize: 18, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 6),
                    Text('验证指纹或面容后继续',
                        style: TextStyle(
                            fontSize: 12, color: Theme.of(context).hintColor)),
                    const SizedBox(height: 20),
                    FilledButton.icon(
                      onPressed: _ask,
                      icon: const Icon(Icons.fingerprint),
                      label: const Text('解锁'),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}