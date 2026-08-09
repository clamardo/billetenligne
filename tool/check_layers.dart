// Enforces the onion dependency rule (ADR-0001).
//
// The rule, stated once: **dependencies point inward only.**
//
//   presentation  →  application  →  domain
//   infrastructure ──────────────────┘   (implements application ports)
//
// A rule that is not enforced by CI is a comment. This one is enforced.
//
//   dart run tool/check_layers.dart
//
// Exits non-zero and names every offending import.

import 'dart:io';

/// One forbidden relationship, with the reason it exists.
final class LayerRule {
  const LayerRule({
    required this.name,
    required this.appliesTo,
    required this.forbidden,
    required this.because,
  });

  final String name;

  /// A path fragment identifying files this rule governs.
  final String appliesTo;

  /// Import patterns those files may not use.
  final List<Pattern> forbidden;

  final String because;
}

const rules = <LayerRule>[
  LayerRule(
    name: 'domain is pure Dart',
    appliesTo: 'packages/bel_domain/lib/',
    forbidden: [
      'package:flutter/',
      'package:flutter_test/',
      'dart:io',
      'dart:ui',
      'package:bel_contracts/',
      'package:bel_design/',
      'package:bel_localization/',
    ],
    because:
        'The domain must run in a test with no device, no network and no '
        'filesystem — that is what makes it testable at thousands of tests a '
        'second, and what lets the same rules compile into the server.',
  ),
  LayerRule(
    name: 'contracts do not depend on UI or infrastructure',
    appliesTo: 'packages/bel_contracts/lib/',
    forbidden: [
      'package:flutter/',
      'dart:io',
      'package:bel_design/',
      'package:dart_frog/',
    ],
    because:
        'The wire format is shared by four clients and a server. A Flutter or '
        'server import here would make it unusable by half of them.',
  ),
  LayerRule(
    name: 'the design system holds no business rules',
    appliesTo: 'packages/bel_design/lib/',
    forbidden: ['package:bel_contracts/', 'dart:io', 'package:http/'],
    because:
        'Kilo renders. A component that knows the wire format is a component '
        'that cannot be rendered in a gallery or a golden test.',
  ),
  LayerRule(
    name: 'presentation never reaches infrastructure',
    appliesTo: '/presentation/',
    forbidden: ['/infrastructure/', 'package:drift/', 'package:dio/'],
    because:
        'A widget that opens a database or an HTTP client cannot be tested '
        'without one, and the dependency direction has been inverted.',
  ),
  LayerRule(
    name: 'application declares ports, it does not implement them',
    appliesTo: '/application/',
    forbidden: ['/infrastructure/', '/presentation/', 'package:flutter/'],
    because:
        'Use cases orchestrate. The moment one imports an adapter, swapping '
        'Airtel for Orange Money stops being a one-file change.',
  ),
];

/// Directories that are generated, vendored or otherwise not ours.
bool _skip(String path) =>
    path.contains('/.dart_tool/') ||
    path.contains('/build/') ||
    path.contains('/.git/') ||
    path.endsWith('.g.dart') ||
    path.endsWith('.freezed.dart');

final _import = RegExp(
  '''^\\s*(?:import|export)\\s+['"]([^'"]+)['"]''',
  multiLine: true,
);

void main(List<String> args) {
  final root = Directory(args.isEmpty ? '.' : args.first);
  final violations = <String>[];
  var scanned = 0;

  for (final entity in root.listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;
    final path = entity.path.replaceAll(r'\', '/');
    if (_skip(path)) continue;
    if (path.contains('/test/') || path.contains('/tool/')) continue;

    scanned++;
    final source = entity.readAsStringSync();
    final imports = _import.allMatches(source).map((m) => m.group(1)!).toList();

    for (final rule in rules) {
      if (!path.contains(rule.appliesTo)) continue;
      for (final import in imports) {
        for (final forbidden in rule.forbidden) {
          if (!import.contains(forbidden)) continue;
          violations.add(
            '$path\n'
            '    imports  $import\n'
            '    breaks   ${rule.name}\n'
            '    because  ${rule.because}',
          );
        }
      }
    }
  }

  stdout.writeln('layer check: $scanned files');

  if (violations.isEmpty) {
    stdout.writeln('[32mOK  dependencies point inward[0m');
    return;
  }

  stdout.writeln('[31m${violations.length} violation(s)[0m\n');
  for (final v in violations) {
    stdout.writeln('  $v\n');
  }
  exitCode = 1;
}
