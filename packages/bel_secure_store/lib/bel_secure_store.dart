/// Where a credential lives between launches on a handset.
///
/// One package rather than a copy in each app, for the same reason the
/// second-factor screen is one widget: two implementations of one security
/// control is two chances for one of them to be wrong, and the one that is
/// wrong is the one nobody looks at again.
library;

export 'src/secure_session_store.dart';
