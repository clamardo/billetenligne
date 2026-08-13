/// Puts a demo world into a database, and takes it out again.
///
///   dart run services/worker/bin/seed_demo.dart
///   dart run services/worker/bin/seed_demo.dart --purge
///
/// The world itself, and the reasoning behind it, is in
/// `package:bel_worker/src/demo_world.dart`.
import 'dart:io';

import 'package:bel_api/src/infrastructure/db/database.dart';
import 'package:bel_worker/src/demo_world.dart';

Future<int> main(List<String> args) async {
  final url = Platform.environment['DATABASE_URL'];
  final seedUrl = Platform.environment['SEED_DATABASE_URL'];

  if (url == null || url.isEmpty || seedUrl == null || seedUrl.isEmpty) {
    stderr.writeln(
      'DATABASE_URL and SEED_DATABASE_URL must both be set. The second is a '
      'superuser connection: creating people and appointing platform staff '
      'are writes no running surface holds a grant for.',
    );
    return 2;
  }

  final db = Database.open(url);
  final seed = await openSeedConnection(seedUrl);
  final world = DemoWorld(db: db, seed: seed);

  try {
    if (args.contains('--purge')) {
      final gone = await world.purge();
      stdout.writeln('── demo world removed ($gone operators)');
      return 0;
    }

    // Re-seeding is re-running, so the script is safe to invoke twice — and
    // the way it is safe is by removing the previous world rather than by
    // trying to reconcile with it. A seeder with an upsert for every row is a
    // second schema nobody maintains.
    await world.purge();
    await world.seed();
    return 0;
  } catch (e, s) {
    stderr.writeln('[seed] failed: $e\n$s');
    return 1;
  } finally {
    await db.close();
    await seed.close();
  }
}
