import 'dart:async';
import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:flutter/widgets.dart';
import 'package:screen_brightness_platform_interface/screen_brightness_platform_interface.dart';

class Backlight {
  final String name;
  final String type;
  final Directory directory;

  Backlight(this.name, this.type, this.directory);

  int get max => _read('max_brightness') ?? 0;

  int? get value => _read('brightness');

  int? _read(String file) {
    try {
      return int.tryParse(File('${directory.path}/$file').readAsStringSync().trim());
    } on FileSystemException {
      return null;
    }
  }

  static int rank(String type) => switch (type) {
    'raw' => 0,
    'platform' => 1,
    'firmware' => 2,
    _ => 3,
  };

  static Backlight? find([String root = '/sys/class/backlight']) {
    final dir = Directory(root);
    if (!dir.existsSync()) return null;
    final found = <Backlight>[];
    for (final entry in dir.listSync()) {
      final name = entry.uri.pathSegments.where((s) => s.isNotEmpty).last;
      final directory = Directory(entry.resolveSymbolicLinksSync());
      String type = '';
      try {
        type = File('${directory.path}/type').readAsStringSync().trim();
      } on FileSystemException {
        type = '';
      }
      final light = Backlight(name, type, directory);
      if (light.max > 0) found.add(light);
    }
    if (found.isEmpty) return null;
    found.sort((a, b) => rank(a.type).compareTo(rank(b.type)));
    return found.first;
  }
}

class ScreenBrightnessLinux extends ScreenBrightnessPlatform
    with WidgetsBindingObserver {
  ScreenBrightnessLinux({this.backlightRoot = '/sys/class/backlight'});

  final String backlightRoot;

  static void registerWith() {
    ScreenBrightnessPlatform.instance = ScreenBrightnessLinux();
  }

  Backlight? _light;
  bool _searched = false;
  DBusClient? _bus;
  double? _original;
  bool _changed = false;
  bool _autoReset = true;
  bool _animate = false;
  bool _observing = false;
  StreamController<double>? _changes;
  Timer? _poll;
  int? _lastRaw;

  Backlight? get _backlight {
    if (!_searched) {
      _searched = true;
      _light = Backlight.find(backlightRoot);
    }
    return _light;
  }

  double _fraction(Backlight light) {
    final raw = light.value ?? 0;
    return (raw / light.max).clamp(0.0, 1.0);
  }

  Future<double> _current() async {
    final light = _backlight;
    if (light == null) {
      throw UnsupportedError('No backlight device under $backlightRoot');
    }
    return _fraction(light);
  }

  Future<void> _write(double brightness) async {
    if (brightness < 0 || brightness > 1) {
      throw RangeError.range(brightness, 0, 1, 'brightness');
    }
    final light = _backlight;
    if (light == null) {
      throw UnsupportedError('No backlight device under $backlightRoot');
    }
    final raw = (brightness * light.max).round().clamp(1, light.max);
    try {
      _bus ??= DBusClient.system();
      final session = DBusRemoteObject(
        _bus!,
        name: 'org.freedesktop.login1',
        path: DBusObjectPath('/org/freedesktop/login1/session/auto'),
      );
      await session.callMethod(
        'org.freedesktop.login1.Session',
        'SetBrightness',
        [DBusString('backlight'), DBusString(light.name), DBusUint32(raw)],
        replySignature: DBusSignature(''),
      );
    } on Object {
      File('${light.directory.path}/brightness').writeAsStringSync('$raw');
    }
  }

  void _observe() {
    if (_observing) return;
    _observing = true;
    try {
      WidgetsBinding.instance.addObserver(this);
    } on Object {
      _observing = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached && _autoReset) {
      unawaited(resetApplicationScreenBrightness());
    }
  }

  @override
  Future<double> get system => _current();

  @override
  Future<void> setSystemScreenBrightness(double brightness) =>
      _write(brightness);

  @override
  Future<double> get application => _current();

  @override
  Future<void> setApplicationScreenBrightness(double brightness) async {
    _original ??= await _current();
    _changed = true;
    _observe();
    await _write(brightness);
  }

  @override
  Future<void> resetApplicationScreenBrightness() async {
    final original = _original;
    _changed = false;
    _original = null;
    if (original != null) await _write(original);
  }

  @override
  Future<bool> get hasApplicationScreenBrightnessChanged async => _changed;

  @override
  Future<bool> get isAutoReset async => _autoReset;

  @override
  Future<void> setAutoReset(bool isAutoReset) async => _autoReset = isAutoReset;

  @override
  Future<bool> get isAnimate async => _animate;

  @override
  Future<void> setAnimate(bool isAnimate) async => _animate = isAnimate;

  @override
  Future<bool> get canChangeSystemBrightness async => _backlight != null;

  Stream<double> get _stream {
    _changes ??= StreamController<double>.broadcast(
      onListen: () {
        _poll = Timer.periodic(const Duration(milliseconds: 700), (_) {
          final light = _backlight;
          final raw = light?.value;
          if (light == null || raw == null || raw == _lastRaw) return;
          _lastRaw = raw;
          _changes?.add(_fraction(light));
        });
      },
      onCancel: () {
        _poll?.cancel();
        _poll = null;
      },
    );
    return _changes!.stream;
  }

  @override
  Stream<double> get onSystemScreenBrightnessChanged => _stream;

  @override
  Stream<double> get onApplicationScreenBrightnessChanged => _stream;
}
