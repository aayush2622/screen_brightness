import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:screen_brightness_linux/screen_brightness_linux.dart';

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('backlight');
  });

  tearDown(() => root.deleteSync(recursive: true));

  Directory device(String name, String type, int value, int max) {
    final dir = Directory('${root.path}/$name')..createSync();
    File('${dir.path}/type').writeAsStringSync(type);
    File('${dir.path}/brightness').writeAsStringSync('$value');
    File('${dir.path}/max_brightness').writeAsStringSync('$max');
    return dir;
  }

  test('prefers raw over firmware devices', () {
    device('acpi_video0', 'firmware', 10, 20);
    device('intel_backlight', 'raw', 50, 100);
    expect(Backlight.find(root.path)?.name, 'intel_backlight');
  });

  test('reports the fraction of the maximum', () async {
    device('intel_backlight', 'raw', 25, 100);
    final plugin = ScreenBrightnessLinux(backlightRoot: root.path);
    expect(await plugin.system, 0.25);
    expect(await plugin.canChangeSystemBrightness, isTrue);
  });

  test('no device means it cannot change brightness', () async {
    final plugin = ScreenBrightnessLinux(backlightRoot: root.path);
    expect(await plugin.canChangeSystemBrightness, isFalse);
    await expectLater(plugin.system, throwsUnsupportedError);
  });

  test('rejects out of range values', () async {
    device('intel_backlight', 'raw', 25, 100);
    final plugin = ScreenBrightnessLinux(backlightRoot: root.path);
    await expectLater(plugin.setSystemScreenBrightness(2), throwsRangeError);
  });
}
