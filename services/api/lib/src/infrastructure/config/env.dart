import 'dart:io';

/// The environment this process actually runs on: what was exported, plus
/// what was mounted, minus the empties.
///
/// Two decisions live here, and both exist because Kubernetes cannot express
/// them.
///
/// **Empty is unset.** Almost everything in `composition.dart` is read as
/// `env['X'] ?? 'a default'`, which treats an empty string as an answer. A
/// ConfigMap is a map of strings with no way to say *no value*, so a key
/// listed before its value exists arrives as `MTN__BASEURL: ""`, and the `??`
/// then replaces a working sandbox host with `Uri.parse('')` — a relative URI
/// against which every call to that rail fails, with an error about a
/// hostname it never had. Absent and empty are the same intent arriving
/// differently, and they are made the same here rather than at each of the
/// forty places that read one.
///
/// **A secret arrives as a file.** `BEL__SECRETSDIR` names a directory whose
/// file names are variable names — the shape every secret store mounts:
/// the Secret Store CSI driver, a Vault agent, a Docker secret, or a `tmpfs`
/// somebody populated by hand. It is a better place for a credential than an
/// environment variable, for reasons that are not stylistic: an environment
/// is inherited by every child process, sits in `/proc/self/environ` for
/// anything that can read the process, and is copied into crash dumps; a file
/// has permissions and is read once, at startup. It also **rotates**: a CSI
/// mount rewrites the file in place, where an environment variable needs the
/// pod recreated.
abstract final class Env {
  /// What the process should read, from what it was given.
  static Map<String, String> resolve(Map<String, String> raw) {
    final env = present(raw);
    final directory = env['BEL__SECRETSDIR'];
    if (directory == null) return env;
    return present({...env, ...mounted(directory)});
  }

  static Map<String, String> present(Map<String, String> raw) => {
    for (final variable in raw.entries)
      if (variable.value.isNotEmpty) variable.key: variable.value,
  };

  /// One variable per file in [path].
  ///
  /// Throws when the directory is not there. A deployment that names a
  /// secrets mount and does not have one is misconfigured, and the quiet
  /// alternative is worse than a refusal: with no `DATABASE_URL` this API
  /// falls back to the in-memory composition and serves invented departures,
  /// which is a green deployment selling seats on coaches that do not exist.
  static Map<String, String> mounted(String path) {
    final directory = Directory(path);
    if (!directory.existsSync()) {
      throw StateError(
        'BEL__SECRETSDIR is $path and there is no such directory. '
        'Either the volume did not mount or the path is wrong; either way '
        'this process has no secrets and must not start.',
      );
    }

    final values = <String, String>{};
    for (final entry in directory.listSync()) {
      if (entry is! File) continue;
      final name = entry.uri.pathSegments.last;
      // Kubernetes projects a volume through a hidden timestamped directory
      // and a `..data` symlink, so a naive listing finds `..data` beside the
      // real names. Skipping dot-entries is what makes this work on the one
      // platform it was written for.
      if (name.startsWith('.')) continue;
      values[name] = _read(entry);
    }
    return values;
  }

  /// The file's contents, without the newline whoever wrote it did not mean.
  ///
  /// `echo secret > file` appends one, `printf` does not, and a
  /// `DATABASE_URL` with a trailing newline fails to connect with an error
  /// about the *host* — which sends somebody to the network for a problem
  /// that is in a text file. Only line breaks are taken: a trailing space is
  /// unlikely and trimming it would be this code rewriting a credential.
  static String _read(File file) {
    var value = file.readAsStringSync();
    while (value.endsWith('\n') || value.endsWith('\r')) {
      value = value.substring(0, value.length - 1);
    }
    return value;
  }
}
