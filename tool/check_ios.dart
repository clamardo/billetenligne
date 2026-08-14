// The iOS projects, checked from a machine that cannot build them.
//
//   dart run tool/check_ios.dart
//
// **Why this exists.** Everything the Android release build got wrong was
// found by making the artifact and opening it. iOS cannot be built here —
// there is no Mac and no Apple team — so the same defects would sit
// undiscovered until the first day somebody has both, and several of them are
// not build failures at all. A missing usage description is a *runtime*
// termination with no dialog and no log; an entitlements file attached to no
// target is a Universal Links claim made nowhere; an icon with an alpha
// channel is a rejection at submission.
//
// So the project files are read as the text they are. This is not a
// substitute for building on a Mac. It is the part that does not need one.

import 'dart:io';

void main() {
  final apps = [
    _IosApp(
      'traveller',
      displayName: 'BilletEnLigne',
      entitlements: true,
      camera: false,
    ),
    _IosApp(
      'scanner',
      displayName: 'BilletEnLigne Contrôle',
      entitlements: false,
      camera: true,
    ),
  ];

  final problems = <String>[];
  var checks = 0;

  void check(String claim, bool holds, String failure) {
    checks++;
    if (holds) {
      stdout.writeln('   OK  $claim');
    } else {
      problems.add(failure);
      stdout.writeln('   \x1B[31mFAIL\x1B[0m  $claim');
    }
  }

  for (final app in apps) {
    stdout.writeln('── ${app.name}');
    final dir = Directory('apps/${app.name}/ios');
    if (!dir.existsSync()) {
      problems.add('apps/${app.name}/ios does not exist');
      continue;
    }
    final plist = File('${dir.path}/Runner/Info.plist').readAsStringSync();
    final project = File(
      '${dir.path}/Runner.xcodeproj/project.pbxproj',
    ).readAsStringSync();

    check(
      'the name under the icon is the brand, not the package',
      _string(plist, 'CFBundleDisplayName') == app.displayName,
      '${app.name}: CFBundleDisplayName is '
          '"${_string(plist, 'CFBundleDisplayName')}"',
    );

    // The one that is a crash rather than a warning.
    if (app.camera) {
      final why = _string(plist, 'NSCameraUsageDescription');
      check(
        'the camera is asked for, in words, before it is opened',
        why != null && why.length > 30,
        '${app.name}: NSCameraUsageDescription is missing or too short — '
            'iOS terminates the process the first time the camera opens',
      );
    }

    check(
      'the export-compliance answer is recorded rather than guessed',
      plist.contains('ITSAppUsesNonExemptEncryption'),
      '${app.name}: no ITSAppUsesNonExemptEncryption — every upload stops to '
          'ask, and a human in a hurry answers it',
    );

    check(
      'the app says it speaks French',
      _array(plist, 'CFBundleLocalizations').contains('fr'),
      '${app.name}: CFBundleLocalizations does not list fr',
    );

    check(
      'the bundle identifier is ours',
      !project.contains('com.example'),
      '${app.name}: a com.example bundle identifier is still in the project',
    );

    // An entitlements file Xcode never reads claims nothing at all, and
    // nothing says so until somebody taps a link on an iPhone.
    final file = File('${dir.path}/Runner/Runner.entitlements');
    check(
      app.entitlements
          ? 'the entitlements file is attached to the Runner target'
          : 'no entitlements are claimed, and none are declared',
      app.entitlements
          ? file.existsSync() &&
                _occurrences(
                      project,
                      'CODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements;',
                    ) ==
                    3
          : !file.existsSync(),
      app.entitlements
          ? '${app.name}: Runner.entitlements is not referenced by all three '
                'build configurations'
          : '${app.name}: an entitlements file with nothing claiming it',
    );

    if (app.entitlements && file.existsSync()) {
      // The domain has to be the one the API serves
      // `/.well-known/apple-app-site-association` from, and unlike Android's
      // manifest placeholder this one is a constant in a signed file.
      check(
        'the associated domain is the one the API serves the claim from',
        file.readAsStringSync().contains('applinks:blt.cg'),
        '${app.name}: the associated-domains entitlement names another host',
      );
    }

    // The set Apple asks for, complete, and none of it transparent.
    final icons = Directory(
      '${dir.path}/Runner/Assets.xcassets/AppIcon.appiconset',
    );
    final pngs = icons.listSync().whereType<File>().where(
      (f) => f.path.endsWith('.png'),
    );
    check(
      'every icon Apple asks for is there',
      pngs.length == 15,
      '${app.name}: ${pngs.length} app icons, expected 15',
    );
    final transparent = [
      for (final png in pngs)
        if (_hasAlpha(png)) png.uri.pathSegments.last,
    ];
    check(
      'no icon carries an alpha channel',
      transparent.isEmpty,
      '${app.name}: icons with an alpha channel, which App Store validation '
          'refuses: ${transparent.join(', ')}',
    );
  }

  stdout.writeln();
  if (problems.isEmpty) {
    stdout.writeln('\x1B[32m── $checks iOS checks passed\x1B[0m');
    return;
  }
  for (final problem in problems) {
    stdout.writeln('\x1B[31m   $problem\x1B[0m');
  }
  stdout.writeln('\x1B[31m── ${problems.length} of $checks failed\x1B[0m');
  exitCode = 1;
}

final class _IosApp {
  const _IosApp(
    this.name, {
    required this.displayName,
    required this.entitlements,
    required this.camera,
  });

  final String name;
  final String displayName;
  final bool entitlements;
  final bool camera;
}

/// The `<string>` that follows a `<key>`. A plist is XML and this is not a
/// parser — it is enough to read six keys out of a file Xcode writes.
String? _string(String plist, String key) => RegExp(
  '<key>$key</key>\\s*<string>([^<]*)</string>',
).firstMatch(plist)?.group(1);

List<String> _array(String plist, String key) {
  final block = RegExp(
    '<key>$key</key>\\s*<array>(.*?)</array>',
    dotAll: true,
  ).firstMatch(plist);
  if (block == null) return const [];
  return [
    for (final m in RegExp(
      '<string>([^<]*)</string>',
    ).allMatches(block.group(1)!))
      m.group(1)!,
  ];
}

int _occurrences(String haystack, String needle) =>
    needle.allMatches(haystack).length;

/// True when the PNG's colour type carries alpha.
///
/// Byte 25 of a PNG is the IHDR colour type: 4 is greyscale+alpha and 6 is
/// truecolour+alpha. Reading it costs no decoder.
bool _hasAlpha(File png) {
  final head = png.openSync()..setPositionSync(25);
  final type = head.readByteSync();
  head.closeSync();
  return type == 4 || type == 6;
}
