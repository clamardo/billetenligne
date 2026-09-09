import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_design/bel_design.dart';
import 'package:bel_platform/bel_platform.dart';
import 'package:flutter/material.dart';

import '../../application/console_workspace.dart';
import '../l10n.dart';

/// Who can be attached to a till.
///
/// `staff.manage` is held by `org_owner`, `org_admin` and `station_manager`
/// (ADR-0011) — so the caller working this screen may themselves be scoped
/// to a handful of stations. The invite and edit dialogs read that scope off
/// `workspace.identity` and offer only what `StaffAssignment` would actually
/// accept, so a station manager never fills in a form the server refuses:
/// the whole-org roles are not in the list, and the station picker shows
/// only the stations they themselves cover.
final class PersonnelScreen extends StatelessWidget {
  const PersonnelScreen({required this.workspace, super.key});

  final ConsoleWorkspace workspace;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    final identity = workspace.identity;
    final wholeOrg = identity == null || identity.stationIds.isEmpty;

    return ListView(
      padding: EdgeInsets.all(kilo.space.s4),
      children: [
        KPageHeader(
          context.t('console.personnel.title'),
          count: workspace.staff.length,
          action: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 260),
            child: KButton(
              label: context.t('console.personnel.invite'),
              fullWidth: false,
              icon: Icons.person_add_alt,
              onPressed: () => _invite(context, wholeOrg: wholeOrg),
            ),
          ),
        ),
        if (workspace.staff.isEmpty)
          KCard(
            child: Text(
              context.t('console.personnel.empty'),
              style: kilo.text.body,
            ),
          )
        else
          for (final member in workspace.staff)
            Padding(
              padding: EdgeInsets.only(bottom: kilo.space.s2),
              child: KCard(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(
                                member.fullName ?? member.phone ?? member.id,
                                style: kilo.text.body,
                              ),
                              if (member.fullName != null &&
                                  member.phone != null) ...[
                                SizedBox(width: kilo.space.s2),
                                Text(
                                  member.phone!,
                                  style: kilo.text.bodySm.copyWith(
                                    color: kilo.color.contentSecondary,
                                  ),
                                ),
                              ],
                              SizedBox(width: kilo.space.s2),
                              if (member.isRevoked)
                                KChip(
                                  context.t('console.personnel.revoked'),
                                  tone: KChipTone.danger,
                                ),
                            ],
                          ),
                          SizedBox(height: kilo.space.s2),
                          Wrap(
                            spacing: kilo.space.s2,
                            runSpacing: kilo.space.s2,
                            children: [
                              for (final role in member.roles)
                                KChip(_roleLabel(context, role)),
                              KChip(
                                member.stationIds.isEmpty
                                    ? context.t('console.personnel.wholeOrg')
                                    : _stationNames(member.stationIds),
                                tone: KChipTone.neutral,
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    if (!member.isRevoked) ...[
                      IconButton(
                        icon: const Icon(Icons.edit_outlined),
                        tooltip: context.t('console.personnel.edit'),
                        onPressed: () =>
                            _edit(context, member: member, wholeOrg: wholeOrg),
                      ),
                      IconButton(
                        icon: const Icon(Icons.person_remove_outlined),
                        tooltip: context.t('console.personnel.revoke'),
                        onPressed: () => _confirmRevoke(context, member),
                      ),
                    ],
                  ],
                ),
              ),
            ),
        // Designing what a role *means* is a whole-org decision, the same as
        // granting `finance` (`CustomRoleDefinition`) — a station manager
        // never sees this section, the same reason they never see the
        // whole-org roles above.
        if (wholeOrg) ...[
          SizedBox(height: kilo.space.s4),
          KPageHeader(
            context.t('console.personnel.rolesTitle'),
            count: workspace.customRoles.length,
            action: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 260),
              child: KButton(
                label: context.t('console.personnel.roleNew'),
                fullWidth: false,
                icon: Icons.add_moderator_outlined,
                onPressed: () => _openRoleDialog(context),
              ),
            ),
          ),
          if (workspace.customRoles.isEmpty)
            KCard(
              child: Text(
                context.t('console.personnel.rolesEmpty'),
                style: kilo.text.body,
              ),
            )
          else
            for (final role in workspace.customRoles)
              Padding(
                padding: EdgeInsets.only(bottom: kilo.space.s2),
                child: KCard(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(role.name, style: kilo.text.body),
                            SizedBox(height: kilo.space.s2),
                            Wrap(
                              spacing: kilo.space.s2,
                              runSpacing: kilo.space.s2,
                              children: [
                                for (final cap in role.capabilities)
                                  KChip(_capabilityLabel(cap)),
                              ],
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.edit_outlined),
                        tooltip: context.t('console.personnel.edit'),
                        onPressed: () =>
                            _openRoleDialog(context, existing: role),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline),
                        tooltip: context.t('console.personnel.roleDelete'),
                        onPressed: () => _confirmDeleteRole(context, role),
                      ),
                    ],
                  ),
                ),
              ),
        ],
      ],
    );
  }

  /// A built-in role's name is a translation key (`console.personnel.role.*`).
  /// A custom role's name is free-form text somebody typed into the design
  /// dialog, and has no key to look up — it is shown as written.
  String _roleLabel(BuildContext context, String role) =>
      StaffAssignment.knownRoles.contains(role)
      ? context.t('console.personnel.role.$role')
      : role;

  /// A readable label for a capability string like `booking.sell`.
  ///
  /// No i18n key per capability: there are around thirty of them across two
  /// languages, and this is the operator's own back office rather than
  /// passenger-facing copy — a light transform of the wire string is legible
  /// enough for the person designing a role.
  String _capabilityLabel(String capability) => capability
      .split(RegExp('[._]'))
      .map(
        (word) => word.isEmpty
            ? word
            : '${word[0].toUpperCase()}${word.substring(1)}',
      )
      .join(' ');

  String _stationNames(List<String> stationIds) {
    final names = [for (final id in stationIds) _stationName(id)];
    return names.join(', ');
  }

  String _stationName(String id) {
    for (final station in workspace.stations) {
      if (station.id == id) return station.name;
    }
    return id;
  }

  /// The roles this caller may grant, and the stations they may grant them
  /// at — a client-side mirror of `StaffAssignment.validate`, not a
  /// replacement for it. The server still enforces the real rule; this is
  /// only why a station manager never sees `finance` in the first place.
  List<String> _grantableRoles(bool wholeOrg) => wholeOrg
      ? ([
          ...StaffAssignment.knownRoles,
          for (final role in workspace.customRoles) role.name,
        ]..sort())
      : (StaffAssignment.stationScopedRoles.toList()..sort());

  List<StationDto> _grantableStations(bool wholeOrg) {
    final identity = workspace.identity;
    if (wholeOrg || identity == null) return workspace.stations;
    return [
      for (final station in workspace.stations)
        if (identity.stationIds.contains(station.id)) station,
    ];
  }

  Future<void> _invite(BuildContext context, {required bool wholeOrg}) =>
      _openDialog(context, wholeOrg: wholeOrg);

  Future<void> _edit(
    BuildContext context, {
    required StaffDto member,
    required bool wholeOrg,
  }) => _openDialog(context, wholeOrg: wholeOrg, existing: member);

  /// One dialog for inviting and for editing an assignment. A second phone
  /// number is not a smaller idea than the first one — it opens a new
  /// membership, not a change to this one — so the phone field is simply
  /// absent when `existing` is set rather than disabled.
  Future<void> _openDialog(
    BuildContext context, {
    required bool wholeOrg,
    StaffDto? existing,
  }) async {
    final phone = TextEditingController(text: existing?.phone ?? '');
    final fullName = TextEditingController(text: existing?.fullName ?? '');
    final staffRef = TextEditingController(text: existing?.staffRef ?? '');
    final roles = _grantableRoles(wholeOrg);
    final stations = _grantableStations(wholeOrg);
    final selectedRoles = {
      for (final role in existing?.roles ?? const <String>[])
        if (roles.contains(role)) role,
    };
    final selectedStations = {
      for (final id in existing?.stationIds ?? const <String>[])
        if (stations.any((s) => s.id == id)) id,
    };

    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setState) {
          // A station-scoped caller may only ever grant `stationScopedRoles`
          // (enforced above, in `_grantableRoles`), and `StaffAssignment`
          // requires at least one station named whenever such a caller is
          // the one granting — so the requirement here is on the caller's
          // own scope, not on which role happens to be checked. A whole-org
          // caller may leave the station list empty; that is "every
          // station", not an unfinished form.
          final canSave =
              selectedRoles.isNotEmpty &&
              (existing != null || phone.text.trim().isNotEmpty) &&
              (wholeOrg || selectedStations.isNotEmpty);

          return AlertDialog(
            title: Text(
              dialogContext.t(
                existing == null
                    ? 'console.personnel.invite'
                    : 'console.personnel.editTitle',
              ),
            ),
            content: SizedBox(
              width: 460,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (existing == null) ...[
                      KField(
                        label: dialogContext.t('console.personnel.phone'),
                        controller: phone,
                        hint: dialogContext.t('console.personnel.phoneHint'),
                        autofocus: true,
                        keyboardType: TextInputType.phone,
                      ),
                      SizedBox(height: dialogContext.kilo.space.s3),
                      KField(
                        label: dialogContext.t('console.personnel.fullName'),
                        controller: fullName,
                        hint: dialogContext.t('console.personnel.fullNameHint'),
                      ),
                      SizedBox(height: dialogContext.kilo.space.s4),
                    ],
                    // The operator's own short number for this person, and
                    // never a credential (ADR-0024): it is printed on the
                    // roster, on the manifest and stuck to the dashboard of
                    // the coach, so accepting it at a sign-in prompt would
                    // add a secret to phish rather than a factor to hold. It
                    // exists so a dispatcher can find the right person in a
                    // list of two hundred.
                    if (existing != null) ...[
                      KField(
                        label: dialogContext.t('console.personnel.staffRef'),
                        controller: staffRef,
                        hint: dialogContext.t(
                          'console.personnel.staffRefHint',
                        ),
                        maxLength: 24,
                      ),
                      SizedBox(height: dialogContext.kilo.space.s4),
                    ],
                    Text(
                      dialogContext.t('console.personnel.roles'),
                      style: dialogContext.kilo.text.label,
                    ),
                    SizedBox(height: dialogContext.kilo.space.s1),
                    for (final role in roles)
                      CheckboxListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        title: Text(_roleLabel(dialogContext, role)),
                        value: selectedRoles.contains(role),
                        onChanged: (checked) => setState(() {
                          if (checked ?? false) {
                            selectedRoles.add(role);
                          } else {
                            selectedRoles.remove(role);
                          }
                        }),
                      ),
                    if (stations.isNotEmpty &&
                        (!wholeOrg ||
                            selectedRoles.any(
                              StaffAssignment.stationScopedRoles.contains,
                            ))) ...[
                      SizedBox(height: dialogContext.kilo.space.s3),
                      Text(
                        dialogContext.t('console.personnel.stations'),
                        style: dialogContext.kilo.text.label,
                      ),
                      SizedBox(height: dialogContext.kilo.space.s1),
                      Text(
                        dialogContext.t(
                          wholeOrg
                              ? 'console.personnel.stationsHelpWholeOrg'
                              : 'console.personnel.stationsHelpScoped',
                        ),
                        style: dialogContext.kilo.text.bodySm.copyWith(
                          color: dialogContext.kilo.color.contentSecondary,
                        ),
                      ),
                      for (final station in stations)
                        CheckboxListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          controlAffinity: ListTileControlAffinity.leading,
                          title: Text(station.name),
                          value: selectedStations.contains(station.id),
                          onChanged: (checked) => setState(() {
                            if (checked ?? false) {
                              selectedStations.add(station.id);
                            } else {
                              selectedStations.remove(station.id);
                            }
                          }),
                        ),
                    ],
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: Text(dialogContext.t('common.actions.cancel')),
              ),
              FilledButton(
                onPressed: canSave
                    ? () => Navigator.of(dialogContext).pop(true)
                    : null,
                child: Text(dialogContext.t('common.actions.save')),
              ),
            ],
          );
        },
      ),
    );

    if (saved != true) return;

    // Whole-org roles carry no station list at all — an empty list is what
    // "every station" means everywhere else in this codebase, and sending
    // one here would ask the server to grant a scope narrower than the
    // caller intended.
    final stationIds =
        selectedRoles.any(StaffAssignment.stationScopedRoles.contains)
        ? selectedStations.toList()
        : const <String>[];

    if (existing == null) {
      await workspace.inviteStaff(
        phone: phone.text.trim(),
        roles: selectedRoles.toList(),
        stationIds: stationIds,
        fullName: fullName.text.trim().isEmpty ? null : fullName.text.trim(),
      );
    } else {
      await workspace.updateStaffAssignment(
        staffId: existing.id,
        roles: selectedRoles.toList(),
        stationIds: stationIds,
        // Blank is no number, not an empty one.
        staffRef: staffRef.text.trim().isEmpty ? null : staffRef.text.trim(),
      );
    }
  }

  Future<void> _confirmRevoke(BuildContext context, StaffDto member) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(dialogContext.t('console.personnel.revoke')),
        content: Text(
          dialogContext.t('console.personnel.revokeConfirm', {
            'a1': member.fullName ?? member.phone ?? member.id,
          }),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(dialogContext.t('common.actions.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(dialogContext.t('console.personnel.revoke')),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await workspace.revokeStaff(member.id);
    }
  }

  /// One dialog for cloning a default role and for editing a custom one.
  /// [existing] absent means "design one" — a "clone from" picker is offered,
  /// the same idea as `_openDialog`'s absent-phone meaning "invite" rather
  /// than "edit".
  Future<void> _openRoleDialog(
    BuildContext context, {
    CustomRoleDto? existing,
  }) async {
    // The union of every default role's own capabilities is the only
    // capability vocabulary the console knows about — the server never
    // hands over `Capability`'s ~30-entry universe directly, and this is
    // that universe's DTO-side stand-in (`DefaultRoleDto`).
    final allCapabilities = {
      for (final role in workspace.defaultRoles) ...role.capabilities,
    }.toList()..sort();

    final name = TextEditingController(text: existing?.name ?? '');
    final selected = {...(existing?.capabilities ?? const <String>[])};
    String? cloneFrom = existing?.clonedFromRole;

    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setState) {
          final canSave = name.text.trim().isNotEmpty && selected.isNotEmpty;

          return AlertDialog(
            title: Text(
              dialogContext.t(
                existing == null
                    ? 'console.personnel.roleNew'
                    : 'console.personnel.roleEditTitle',
              ),
            ),
            content: SizedBox(
              width: 460,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (existing == null &&
                        workspace.defaultRoles.isNotEmpty) ...[
                      Text(
                        dialogContext.t('console.personnel.roleCloneFrom'),
                        style: dialogContext.kilo.text.label,
                      ),
                      SizedBox(height: dialogContext.kilo.space.s1),
                      DropdownButton<String?>(
                        value: cloneFrom,
                        isExpanded: true,
                        hint: Text(
                          dialogContext.t('console.personnel.roleFromScratch'),
                        ),
                        items: [
                          DropdownMenuItem(
                            child: Text(
                              dialogContext.t(
                                'console.personnel.roleFromScratch',
                              ),
                            ),
                          ),
                          for (final role in workspace.defaultRoles)
                            DropdownMenuItem(
                              value: role.name,
                              child: Text(_roleLabel(dialogContext, role.name)),
                            ),
                        ],
                        onChanged: (value) => setState(() {
                          cloneFrom = value;
                          final base = workspace.defaultRoles
                              .where((role) => role.name == value)
                              .firstOrNull;
                          selected
                            ..clear()
                            ..addAll(base?.capabilities ?? const []);
                          if (base != null && name.text.trim().isEmpty) {
                            name.text = dialogContext.t(
                              'console.personnel.roleClonedName',
                              {'a1': _roleLabel(dialogContext, base.name)},
                            );
                          }
                        }),
                      ),
                      SizedBox(height: dialogContext.kilo.space.s3),
                    ],
                    KField(
                      label: dialogContext.t('console.personnel.roleName'),
                      controller: name,
                      autofocus: true,
                    ),
                    SizedBox(height: dialogContext.kilo.space.s4),
                    Text(
                      dialogContext.t('console.personnel.roleCapabilities'),
                      style: dialogContext.kilo.text.label,
                    ),
                    SizedBox(height: dialogContext.kilo.space.s1),
                    for (final capability in allCapabilities)
                      CheckboxListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        title: Text(_capabilityLabel(capability)),
                        value: selected.contains(capability),
                        onChanged: (checked) => setState(() {
                          if (checked ?? false) {
                            selected.add(capability);
                          } else {
                            selected.remove(capability);
                          }
                        }),
                      ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: Text(dialogContext.t('common.actions.cancel')),
              ),
              FilledButton(
                onPressed: canSave
                    ? () => Navigator.of(dialogContext).pop(true)
                    : null,
                child: Text(dialogContext.t('common.actions.save')),
              ),
            ],
          );
        },
      ),
    );

    if (saved != true) return;

    if (existing == null) {
      await workspace.createCustomRole(
        name: name.text.trim(),
        capabilities: selected.toList(),
        clonedFromRole: cloneFrom,
      );
    } else {
      await workspace.updateCustomRole(
        roleId: existing.id,
        name: name.text.trim(),
        capabilities: selected.toList(),
      );
    }
  }

  Future<void> _confirmDeleteRole(
    BuildContext context,
    CustomRoleDto role,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(dialogContext.t('console.personnel.roleDelete')),
        content: Text(
          dialogContext.t('console.personnel.roleDeleteConfirm', {
            'a1': role.name,
          }),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(dialogContext.t('common.actions.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(dialogContext.t('console.personnel.roleDelete')),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await workspace.deleteCustomRole(role.id);
    }
  }
}
