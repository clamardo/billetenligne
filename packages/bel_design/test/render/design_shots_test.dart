import 'package:bel_design/bel_design.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'render_harness.dart';

/// Renders contact sheets to `build/design/` (gitignored) so the design can
/// be *looked at* rather than only read. A component written blind and
/// reviewed only through its source is a component nobody has seen, and that
/// is how a product ends up flat while every test passes.
///
/// These make no assertions, but they are not decoration: laying every piece
/// of artwork and every themed control out at once is the cheapest way to
/// catch a drawing that fails to parse or a control that overflows.
void main() {
  for (final b in KiloBrightness.values) {
    testWidgets('illustrations ${b.name}', (tester) async {
      await shoot(
        tester,
        'illustrations-${b.name}',
        _Sheet(
          title: 'Illustrations',
          children: [
            for (final art in KArt.values)
              _Cell(art.name, KIllustration(art, size: 200)),
          ],
        ),
        size: const Size(700, 940),
        brightness: b,
      );
    });

    testWidgets('scenes ${b.name}', (tester) async {
      await shoot(
        tester,
        'scenes-${b.name}',
        _Sheet(
          title: 'Heroes',
          children: [
            for (final s in KSceneArt.values)
              SizedBox(
                width: 640,
                child: _Cell(s.name, KScene(s, height: 190)),
              ),
          ],
        ),
        size: const Size(700, 760),
        brightness: b,
      );
    });

    testWidgets('components ${b.name}', (tester) async {
      await shoot(
        tester,
        'components-${b.name}',
        const _Components(),
        size: const Size(520, 960),
        brightness: b,
      );
    });
  }

  for (final b in [KiloBrightness.light, KiloBrightness.dark]) {
    testWidgets('expressive ${b.name}', (tester) async {
      await shoot(
        tester,
        'expressive-${b.name}',
        const _Expressive(),
        size: const Size(420, 760),
        brightness: b,
      );
    });
  }

  testWidgets('patterns', (tester) async {
    await shoot(
      tester,
      'patterns',
      _Sheet(
        title: 'Patterns',
        children: [
          for (final m in KPatternMotif.values)
            SizedBox(
              width: 300,
              child: _Cell(
                m.name,
                KPattern(
                  motif: m,
                  height: 90,
                  background: const Color(0xFFE4F1EB),
                ),
              ),
            ),
        ],
      ),
      size: const Size(700, 460),
    );
  });
}

class _Sheet extends StatelessWidget {
  const _Sheet({required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 16),
          Wrap(spacing: 16, runSpacing: 16, children: children),
        ],
      ),
    ),
  );
}

class _Cell extends StatelessWidget {
  const _Cell(this.label, this.child);
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: context.kilo.color.borderSubtle),
          borderRadius: context.kilo.radius.cardBorder,
        ),
        child: ClipRRect(
          borderRadius: context.kilo.radius.cardBorder,
          child: child,
        ),
      ),
      const SizedBox(height: 4),
      Text(label, style: Theme.of(context).textTheme.labelSmall),
    ],
  );
}

class _Components extends StatelessWidget {
  const _Components();

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Composants'),
      actions: const [IconButton(onPressed: null, icon: Icon(Icons.more_vert))],
    ),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Brazzaville → P.-Noire',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 4),
                Text(
                  'Départ 07 h 30',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const Divider(height: 24),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    const Chip(label: Text('Clim')),
                    const Chip(label: Text('4 pl.')),
                    Text(
                      '15 000 F',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton(onPressed: () {}, child: const Text('Réserver')),
            OutlinedButton(onPressed: () {}, child: const Text('Détails')),
            TextButton(onPressed: () {}, child: const Text('Annuler')),
          ],
        ),
        const SizedBox(height: 16),
        const TextField(
          decoration: InputDecoration(
            labelText: 'Téléphone',
            hintText: '06 000 00 00',
            prefixIcon: Icon(Icons.phone_outlined),
          ),
        ),
        const SizedBox(height: 16),
        SegmentedButton<int>(
          segments: const [
            ButtonSegment(value: 0, label: Text('Aller')),
            ButtonSegment(value: 1, label: Text('Retour')),
          ],
          selected: const {0},
          onSelectionChanged: (_) {},
        ),
        const SizedBox(height: 16),
        Card(
          child: Column(
            children: const [
              ListTile(
                leading: Icon(Icons.confirmation_number_outlined),
                title: Text('Billet BEL-4821'),
                subtitle: Text('Confirmé · place 14'),
                trailing: Icon(Icons.chevron_right),
              ),
              Divider(height: 1),
              ListTile(
                leading: Icon(Icons.account_balance_wallet_outlined),
                title: Text('Mobile Money'),
                subtitle: Text('MTN · finit par 42'),
                trailing: Icon(Icons.chevron_right),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        const LinearProgressIndicator(value: 0.6),
        const SizedBox(height: 16),
        Row(
          children: [
            Switch(value: true, onChanged: (_) {}),
            Checkbox(value: true, onChanged: (_) {}),
            const Icon(Icons.star_rounded),
          ],
        ),
      ],
    ),
    bottomNavigationBar: NavigationBar(
      selectedIndex: 0,
      destinations: const [
        NavigationDestination(icon: Icon(Icons.search), label: 'Chercher'),
        NavigationDestination(
          icon: Icon(Icons.confirmation_number_outlined),
          label: 'Billets',
        ),
        NavigationDestination(
          icon: Icon(Icons.person_outline),
          label: 'Compte',
        ),
      ],
    ),
  );
}

class _Expressive extends StatelessWidget {
  const _Expressive();

  @override
  Widget build(BuildContext context) => Scaffold(
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const KTicketHeader(
          origin: 'BZV',
          destination: 'PNR',
          subtitle: 'sam. 15 août · 06 h 00',
          footnote: 'Ocean du Nord · voiture 2, place 14',
          accent: AccentHue.prune,
        ),
        const SizedBox(height: 24),
        const KSectionHeader(
          'À traiter',
          count: 7,
          subtitle: 'Dossiers en attente de décision',
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const KStat(value: '128', label: 'Places'),
                const KStat(value: '92 %', label: 'Remplissage'),
                KStat(
                  value: '3',
                  label: 'Retards',
                  tone: context.kilo.color.danger,
                  icon: Icons.warning_amber_rounded,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 24),
        const KSectionHeader('En cours de chargement'),
        KSkeleton.list(rows: 3),
      ],
    ),
  );
}
