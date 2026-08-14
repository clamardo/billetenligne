/// The environment, with the empties taken out.
///
/// Almost everything in `composition.dart` is read as
/// `env['X'] ?? 'a default'`, which treats an empty string as an answer. That
/// is the right reading of an environment variable somebody deliberately set
/// to nothing — and the wrong reading of the thing that actually produces
/// them here.
///
/// Kubernetes has no way to say *this key has no value*. A ConfigMap or a
/// Secret is a map of strings, so a template with the keys filled in and the
/// values not — which is what every one of these files looks like before a
/// deployment has credentials — arrives as `MTN__BASEURL: ""`. The `??` then
/// replaces a working sandbox host with `Uri.parse('')`, a relative URI, and
/// every call to that rail fails against nothing with an error about a
/// hostname it never had.
///
/// Absent and empty are the same intent and arrive differently. They are made
/// the same here, once, rather than at each of the forty places that read one.
abstract final class Env {
  static Map<String, String> present(Map<String, String> raw) => {
    for (final variable in raw.entries)
      if (variable.value.isNotEmpty) variable.key: variable.value,
  };
}
