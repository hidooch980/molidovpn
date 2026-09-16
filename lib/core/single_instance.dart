import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Windows only: refuses a second launch instead of letting two copies fight over the same TUN adapter
/// and sing-box port — exactly what made connections flaky and random: one instance holding the adapter,
/// the other silently failing to bind, each showing a different, wrong idea of the real state.
///
/// A named mutex is the standard, race-free way to detect "another copy of me is already running":
/// `CreateMutexW` either creates it (we are first) or, if it already exists, still succeeds but sets
/// `ERROR_ALREADY_EXISTS` — that is the second-instance signal, checked *before* anything else starts
/// (VPN engine, tray icon, update checks), so a second launch never touches the network stack at all.
class SingleInstance {
  static const _mutexName = r'Global\MolidoVPN-SingleInstance-6b6f6d6f';
  static const _windowTitle = 'MolidoVPN';
  static const _errorAlreadyExists = 183;

  static final _kernel32 = DynamicLibrary.open('kernel32.dll');
  static final _createMutex = _kernel32.lookupFunction<
      IntPtr Function(Pointer<Void>, Int32, Pointer<Utf16>),
      int Function(Pointer<Void>, int, Pointer<Utf16>)>('CreateMutexW');
  static final _getLastError = _kernel32.lookupFunction<Uint32 Function(), int Function()>('GetLastError');

  static final _user32 = DynamicLibrary.open('user32.dll');
  static final _findWindow = _user32.lookupFunction<IntPtr Function(Pointer<Utf16>, Pointer<Utf16>),
      int Function(Pointer<Utf16>, Pointer<Utf16>)>('FindWindowW');
  static final _isIconic = _user32.lookupFunction<Int32 Function(IntPtr), int Function(int)>('IsIconic');
  static final _showWindow =
      _user32.lookupFunction<Int32 Function(IntPtr, Int32), int Function(int, int)>('ShowWindow');
  static final _setForegroundWindow =
      _user32.lookupFunction<Int32 Function(IntPtr), int Function(int)>('SetForegroundWindow');
  static const _swRestore = 9;

  /// True when this is the only running instance (mutex acquired). When false, the existing window is
  /// brought to the front and the caller must exit immediately without starting anything else.
  static bool acquire() {
    if (!Platform.isWindows) return true;
    try {
      final handle = using((arena) => _createMutex(nullptr, 0, _mutexName.toNativeUtf16(allocator: arena)));
      final alreadyRunning = handle == 0 || _getLastError() == _errorAlreadyExists;
      if (alreadyRunning) {
        _focusExisting();
        return false;
      }
      return true;
    } catch (_) {
      // Never let a detection failure block a legitimate single launch.
      return true;
    }
  }

  static void _focusExisting() {
    try {
      final hwnd = using((arena) => _findWindow(nullptr, _windowTitle.toNativeUtf16(allocator: arena)));
      if (hwnd == 0) return;
      if (_isIconic(hwnd) != 0) _showWindow(hwnd, _swRestore);
      _setForegroundWindow(hwnd);
    } catch (_) {}
  }
}
