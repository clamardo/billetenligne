import 'package:bel_client/bel_client.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_design/bel_design.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:flutter/material.dart';

import '../../application/onboarding_workspace.dart';
import '../l10n.dart';

/// Self-signup, as the applicant meets it (`03-operator-lifecycle.md` §2.2).
///
/// **This screen exists instead of the console, not inside it.** Somebody who
/// has signed in and belongs to no operator has no fleet, no till and no
/// today; showing them the console with every tab empty would be showing them
/// a product that appears broken. They get their application, and the console
/// appears the moment we activate them.
///
/// Three design rules from §2.2 are load-bearing here rather than decorative:
///
///   * **Show what is missing, always.** The checklist is on screen at every
///     step, and it is `ApplicationFacts.missing` — the same list the server
///     refuses a submission with, so the button and the refusal can never
///     disagree.
///   * **Save on every field.** Typing is never blocked on a request; the
///     record is held locally and pushed whole, and unsaved work says so.
///   * **Plain French, no jargon.** "Numéro RCCM (registre du commerce)",
///     not "RCCM" — the labels are catalog entries, not column names.
final class OnboardingScreen extends StatelessWidget {
  const OnboardingScreen({required this.workspace, super.key});

  final OnboardingWorkspace workspace;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          workspace.application == null
              ? context.t('console.onboarding.startTitle')
              : context.t('console.onboarding.title'),
        ),
        bottom: workspace.busy
            ? const PreferredSize(
                preferredSize: Size.fromHeight(2),
                child: LinearProgressIndicator(minHeight: 2),
              )
            : null,
      ),
      body: Column(
        children: [
          if (workspace.failure != null)
            _Banner(
              text: context.t(
                workspace.failure!.messageKey,
                workspace.failure is ServerRefused
                    ? (workspace.failure! as ServerRefused).params
                    : const {},
              ),
              tone: kilo.color.dangerSoft,
              foreground: kilo.color.danger,
            ),
          if (workspace.notice != null)
            _Banner(
              text: context.t('console.notice.${workspace.notice}'),
              tone: kilo.color.successSoft,
              foreground: kilo.color.success,
            ),
          Expanded(
            child: workspace.application == null
                ? _Start(workspace: workspace)
                : _Wizard(workspace: workspace),
          ),
        ],
      ),
    );
  }
}

/// One field: the company name. Everything else waits.
///
/// §2.1 wants the applicant looking at something of their own inside fifteen
/// minutes, and a signup form that asks for an RCCM number before it shows
/// anything is a form people close.
class _Start extends StatefulWidget {
  const _Start({required this.workspace});

  final OnboardingWorkspace workspace;

  @override
  State<_Start> createState() => _StartState();
}

class _StartState extends State<_Start> {
  final _name = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: ListView(
          shrinkWrap: true,
          padding: EdgeInsets.all(kilo.space.s5),
          children: [
            Text(
              context.t('console.onboarding.startTitle'),
              style: kilo.text.h2,
            ),
            SizedBox(height: kilo.space.s2),
            Text(
              context.t('console.onboarding.startIntro'),
              style: kilo.text.body.copyWith(
                color: kilo.color.contentSecondary,
              ),
            ),
            SizedBox(height: kilo.space.s4),
            KField(
              label: context.t('console.onboarding.companyName'),
              controller: _name,
              autofocus: true,
              onChanged: (_) => setState(() {}),
            ),
            SizedBox(height: kilo.space.s4),
            KButton(
              label: context.t('console.onboarding.begin'),
              onPressed: _name.text.trim().length < 3
                  ? null
                  : () => widget.workspace.begin(_name.text.trim()),
            ),
          ],
        ),
      ),
    );
  }
}

class _Wizard extends StatelessWidget {
  const _Wizard({required this.workspace});

  final OnboardingWorkspace workspace;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // The steps, with the truth about each one beside it. A progress bar
        // that counts pages visited rather than gaps closed is a progress bar
        // that lies at exactly the moment it matters.
        SizedBox(
          width: 260,
          child: ListView(
            padding: EdgeInsets.all(kilo.space.s3),
            children: [
              for (final step in ApplicationStep.values)
                _StepTile(
                  step: step,
                  selected: step == workspace.step,
                  complete: workspace.isComplete(step),
                  outstanding: workspace.missingIn(step).length,
                  onTap: () => workspace.openStep(step),
                ),
            ],
          ),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          child: Column(
            children: [
              Expanded(
                child: ListView(
                  padding: EdgeInsets.all(kilo.space.s4),
                  children: [
                    if (workspace.isUnderReview)
                      KCard(
                        tone: kilo.color.brandAccentSoft,
                        child: Text(
                          context.t('console.onboarding.underReview'),
                          style: kilo.text.body,
                        ),
                      ),
                    if (workspace.application?.decisionReason != null) ...[
                      SizedBox(height: kilo.space.s3),
                      KCard(
                        tone: kilo.color.warningSoft,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              context.t('console.onboarding.reviewerAsked'),
                              style: kilo.text.label,
                            ),
                            SizedBox(height: kilo.space.s1),
                            // A reviewer's own sentence, quoted. There is no
                            // catalog key for what a person typed about this
                            // specific application.
                            Text(
                              workspace.application!.decisionReason!,
                              style: kilo.text.body,
                            ),
                          ],
                        ),
                      ),
                    ],
                    SizedBox(height: kilo.space.s3),
                    _StepFields(workspace: workspace),
                  ],
                ),
              ),
              _Footer(workspace: workspace),
            ],
          ),
        ),
      ],
    );
  }
}

class _StepTile extends StatelessWidget {
  const _StepTile({
    required this.step,
    required this.selected,
    required this.complete,
    required this.outstanding,
    required this.onTap,
  });

  final ApplicationStep step;
  final bool selected;
  final bool complete;
  final int outstanding;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;

    return ListTile(
      selected: selected,
      onTap: onTap,
      leading: Icon(
        complete ? Icons.check_circle : Icons.radio_button_unchecked,
        color: complete ? kilo.color.success : kilo.color.contentSecondary,
      ),
      title: Text(context.t('application.step.${step.name}')),
      subtitle: complete
          ? null
          : Text(
              '$outstanding',
              style: kilo.text.caption.copyWith(
                color: kilo.color.contentSecondary,
              ),
            ),
    );
  }
}

/// The fields of the open step, and only those.
class _StepFields extends StatelessWidget {
  const _StepFields({required this.workspace});

  final OnboardingWorkspace workspace;

  bool get _enabled => !workspace.isUnderReview;

  /// One field changed, on an immutable record.
  ///
  /// Through the wire codec rather than through `copyWith`, and that is a
  /// choice worth stating: `copyWith` cannot *clear* a field, so an operator
  /// deleting their trading name would be a change the server never hears
  /// about. Round-tripping the DTO also means the field names this screen
  /// uses are the field names the API takes — one list, not two.
  void _set(String field, Object? value) {
    final json = ApplicationFactsDto(workspace.facts).toJson();
    json[field] = value;
    workspace.edit(ApplicationFactsDto.fromJson(json).facts);
  }

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    final facts = workspace.facts;

    return Column(
      key: ValueKey(workspace.step),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          context.t('application.step.${workspace.step.name}'),
          style: kilo.text.h3,
        ),
        SizedBox(height: kilo.space.s3),
        ...switch (workspace.step) {
          ApplicationStep.entreprise => [
            _text(context, 'legalName', facts.legalName),
            _text(context, 'tradingName', facts.tradingName),
            _text(context, 'rccmNumber', facts.rccmNumber),
            _text(context, 'taxId', facts.taxId),
            _choice(context, 'legalForm', facts.legalForm, const [
              'sarl',
              'sa',
              'ets',
              'other',
            ], 'console.onboarding.legalForm'),
            _text(context, 'registeredAddress', facts.registeredAddress),
            _number(context, 'yearFounded', facts.yearFounded),
          ],
          ApplicationStep.dirigeant => [
            _text(context, 'ownerName', facts.ownerName),
            _choice(context, 'ownerIdType', facts.ownerIdType, const [
              'passport',
              'national_id',
              'driving_licence',
            ], 'console.onboarding.idType'),
            _text(context, 'ownerIdNumber', facts.ownerIdNumber),
            _text(context, 'ownerPhone', facts.ownerPhone),
            _text(context, 'ownerEmail', facts.ownerEmail),
          ],
          ApplicationStep.licences => [
            KCard(
              tone: kilo.color.brandAccentSoft,
              child: Text(
                context.t('console.onboarding.documentsLater'),
                style: kilo.text.caption,
              ),
            ),
            SizedBox(height: kilo.space.s3),
            _text(
              context,
              'transportLicenceNumber',
              facts.transportLicenceNumber,
            ),
            _date(
              context,
              'transportLicenceExpires',
              facts.transportLicenceExpires,
            ),
            _text(context, 'insurerName', facts.insurerName),
            _date(
              context,
              'fleetInsuranceExpires',
              facts.fleetInsuranceExpires,
            ),
          ],
          ApplicationStep.exploitation => [
            _text(context, 'routesServed', facts.routesServed, lines: 3),
            _number(context, 'fleetSize', facts.fleetSize),
            _number(context, 'stationCount', facts.stationCount),
            _number(context, 'dailyDepartures', facts.dailyDepartures),
          ],
          ApplicationStep.encaissement => [
            _choice(
              context,
              'settlementKind',
              facts.settlementKind,
              const ['momo', 'bank'],
              'console.onboarding.settlementKind',
            ),
            _text(
              context,
              'settlementAccountName',
              facts.settlementAccountName,
            ),
            _text(context, 'settlementAccountRef', facts.settlementAccountRef),
          ],
          ApplicationStep.accord => [
            Text(context.t('console.onboarding.accord'), style: kilo.text.body),
            SizedBox(height: kilo.space.s3),
            CheckboxListTile(
              value: facts.agreementAccepted,
              onChanged: _enabled
                  ? (v) => _set('agreementAccepted', v ?? false)
                  : null,
              title: Text(context.t('console.onboarding.accept')),
            ),
          ],
        },
      ],
    );
  }

  Widget _text(
    BuildContext context,
    String field,
    String? value, {
    int lines = 1,
  }) => Padding(
    padding: EdgeInsets.only(bottom: context.kilo.space.s3),
    child: KField(
      key: ValueKey('${workspace.step.name}.$field'),
      label: context.t('application.field.$field'),
      controller: _controller(field, value ?? ''),
      enabled: _enabled,
      maxLines: lines,
      onChanged: (v) => _set(field, v.isEmpty ? null : v),
    ),
  );

  Widget _number(BuildContext context, String field, int? value) => Padding(
    padding: EdgeInsets.only(bottom: context.kilo.space.s3),
    child: KField(
      key: ValueKey('${workspace.step.name}.$field'),
      label: context.t('application.field.$field'),
      controller: _controller(field, value?.toString() ?? ''),
      enabled: _enabled,
      keyboardType: TextInputType.number,
      onChanged: (v) => _set(field, int.tryParse(v.trim())),
    ),
  );

  /// A day, typed as `AAAA-MM-JJ`.
  ///
  /// Not a calendar picker: a certificate expiring in 2032 is a long way away
  /// in a month-by-month picker, and everybody filling this in is reading the
  /// date off a piece of paper in front of them.
  Widget _date(BuildContext context, String field, DateTime? value) => Padding(
    padding: EdgeInsets.only(bottom: context.kilo.space.s3),
    child: KField(
      key: ValueKey('${workspace.step.name}.$field'),
      label: context.t('application.field.$field'),
      controller: _controller(field, _isoDay(value)),
      enabled: _enabled,
      hint: 'AAAA-MM-JJ',
      onChanged: (v) => _set(field, _isoDay(_parseDay(v))),
    ),
  );

  Widget _choice(
    BuildContext context,
    String field,
    String? value,
    List<String> options,
    String prefix,
  ) => Padding(
    padding: EdgeInsets.only(bottom: context.kilo.space.s3),
    child: InputDecorator(
      decoration: InputDecoration(
        labelText: context.t('application.field.$field'),
        border: const OutlineInputBorder(),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          key: ValueKey('${workspace.step.name}.$field'),
          value: options.contains(value) ? value : null,
          isExpanded: true,
          onChanged: _enabled ? (v) => _set(field, v) : null,
          items: [
            for (final option in options)
              DropdownMenuItem(
                value: option,
                child: Text(context.t('$prefix.$option')),
              ),
          ],
        ),
      ),
    ),
  );

  /// A controller whose text is the record's, with the caret left at the end.
  ///
  /// The field is rebuilt on every keystroke because the record is the single
  /// source of truth; without moving the caret the cursor jumps to the start
  /// on the second character, which is the classic version of this bug.
  static TextEditingController _controller(String field, String text) =>
      TextEditingController(text: text)
        ..selection = TextSelection.collapsed(offset: text.length);

  static String _isoDay(DateTime? v) => v == null
      ? ''
      : '${v.year.toString().padLeft(4, '0')}-'
            '${v.month.toString().padLeft(2, '0')}-'
            '${v.day.toString().padLeft(2, '0')}';

  static DateTime? _parseDay(String raw) {
    final parsed = DateTime.tryParse(raw.trim());
    return parsed == null
        ? null
        : DateTime.utc(parsed.year, parsed.month, parsed.day);
  }
}

/// What is missing, and the two buttons.
class _Footer extends StatelessWidget {
  const _Footer({required this.workspace});

  final OnboardingWorkspace workspace;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    final missing = workspace.missing;

    return Material(
      color: kilo.color.surfaceRaised,
      child: Padding(
        padding: EdgeInsets.all(kilo.space.s3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    missing.isEmpty
                        ? context.t('console.onboarding.nothingMissing')
                        : '${context.t('console.onboarding.missingTitle')} : '
                              '${missing.take(4).map((f) => context.t('application.field.$f')).join(', ')}'
                              '${missing.length > 4 ? ' …' : ''}',
                    style: kilo.text.caption,
                  ),
                  if (workspace.hasUnsavedChanges)
                    Text(
                      context.t('console.onboarding.unsaved'),
                      style: kilo.text.caption.copyWith(
                        color: kilo.color.warning,
                      ),
                    ),
                ],
              ),
            ),
            if (!workspace.isUnderReview) ...[
              SizedBox(width: kilo.space.s3),
              KButton(
                label: context.t('console.onboarding.save'),
                tone: KButtonTone.secondary,
                fullWidth: false,
                onPressed: workspace.busy ? null : workspace.saveNow,
              ),
              SizedBox(width: kilo.space.s2),
              KButton(
                label: context.t('console.onboarding.submit'),
                fullWidth: false,
                onPressed: workspace.canSubmit && !workspace.busy
                    ? workspace.submit
                    : null,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({
    required this.text,
    required this.tone,
    required this.foreground,
  });

  final String text;
  final Color tone;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    return Container(
      width: double.infinity,
      color: tone,
      padding: EdgeInsets.symmetric(
        horizontal: kilo.space.s4,
        vertical: kilo.space.s3,
      ),
      child: Text(text, style: kilo.text.body.copyWith(color: foreground)),
    );
  }
}
