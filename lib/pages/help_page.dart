import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../widgets/app_scale_metrics.dart';
import '../utils/web_mailto.dart';

enum _HelpTab { calculationMethods, indicators, contact }

class HelpPage extends StatefulWidget {
  const HelpPage({super.key});

  @override
  State<HelpPage> createState() => _HelpPageState();
}

class _HelpPageState extends State<HelpPage> {
  static const String _supportEmail = 'connect@8answers.com';
  static const String _helpTabPrefKey = 'nav_help_active_tab';

  final ScrollController _scrollController = ScrollController();
  _HelpTab _selectedTab = _HelpTab.calculationMethods;

  _HelpTab? _parseHelpTabName(String? value) {
    final normalized = (value ?? '').trim();
    if (normalized.isEmpty) return null;
    for (final tab in _HelpTab.values) {
      if (tab.name == normalized) return tab;
    }
    return null;
  }

  Future<void> _restoreSelectedTab() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final restored = _parseHelpTabName(prefs.getString(_helpTabPrefKey));
      if (restored == null || !mounted || _selectedTab == restored) return;
      setState(() {
        _selectedTab = restored;
      });
    } catch (_) {
      // Best-effort restore only.
    }
  }

  Future<void> _persistSelectedTab(_HelpTab tab) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_helpTabPrefKey, tab.name);
    } catch (_) {
      // Best-effort persistence only.
    }
  }

  void _setSelectedTab(_HelpTab tab, {bool persist = true}) {
    if (_selectedTab != tab) {
      if (mounted) {
        setState(() {
          _selectedTab = tab;
        });
      } else {
        _selectedTab = tab;
      }
    }
    if (persist) {
      unawaited(_persistSelectedTab(tab));
    }
  }

  @override
  void initState() {
    super.initState();
    unawaited(_restoreSelectedTab());
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  BoxDecoration get _cardDecoration => BoxDecoration(
        color: const Color(0xFFF8F9FA),
        borderRadius: BorderRadius.circular(8),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.25),
            blurRadius: 2,
            offset: const Offset(0, 0),
          ),
        ],
      );

  Future<void> _copySupportEmail() async {
    await Clipboard.setData(const ClipboardData(text: _supportEmail));
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Support email copied',
          style: GoogleFonts.inter(
            fontSize: 14,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }

  void _openSupportEmailCompose() {
    final opened = openMailTo(_supportEmail);
    if (!opened) {
      _copySupportEmail();
    }
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final isCompact = screenWidth < 768;
    final scaleMetrics = AppScaleMetrics.of(context);
    final designViewportWidth =
        scaleMetrics?.designViewportWidth ?? screenWidth;
    final extraRightWidth = designViewportWidth > screenWidth
        ? (designViewportWidth - screenWidth)
        : 0.0;
    final horizontalPadding = isCompact ? 16.0 : 24.0;

    return Container(
      color: Colors.white,
      child: Padding(
        padding: const EdgeInsets.only(top: 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'How can we help you?',
                    style: GoogleFonts.inter(
                      fontSize: isCompact ? 30 : 32,
                      fontWeight: FontWeight.w600,
                      color: Colors.black,
                      height: 1.25,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Find guidance on using the platform, understanding reports, and resolving common issues.',
                    style: GoogleFonts.inter(
                      fontSize: isCompact ? 18 : 20,
                      fontWeight: FontWeight.w400,
                      color: Colors.black.withValues(alpha: 0.8),
                      height: 1.2,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            SizedBox(
              height: 32,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned(
                    left: 0,
                    right: -extraRightWidth,
                    bottom: 0,
                    child: Container(
                      height: 0.5,
                      color: const Color(0xFF5C5C5C),
                    ),
                  ),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        SizedBox(width: horizontalPadding),
                        _buildTabItem(
                          label: 'Calculation Methods',
                          tab: _HelpTab.calculationMethods,
                        ),
                        const SizedBox(width: 36),
                        _buildTabItem(
                          label: 'Indicators',
                          tab: _HelpTab.indicators,
                        ),
                        const SizedBox(width: 36),
                        _buildTabItem(
                          label: 'Contact',
                          tab: _HelpTab.contact,
                        ),
                        SizedBox(width: horizontalPadding),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ScrollbarTheme(
                data: ScrollbarThemeData(
                  thickness: WidgetStateProperty.all(8),
                  thumbVisibility: WidgetStateProperty.all(true),
                  radius: const Radius.circular(4),
                  minThumbLength: 233,
                ),
                child: Scrollbar(
                  controller: _scrollController,
                  child: SingleChildScrollView(
                    controller: _scrollController,
                    clipBehavior: Clip.hardEdge,
                    padding: EdgeInsets.only(
                      top: 24,
                      left: horizontalPadding,
                      right: horizontalPadding,
                      bottom: 24,
                    ),
                    child: _buildSelectedTabContent(isCompact: isCompact),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTabItem({
    required String label,
    required _HelpTab tab,
  }) {
    final isActive = _selectedTab == tab;
    return InkWell(
      onTap: () {
        if (_selectedTab == tab) return;
        _setSelectedTab(tab);
      },
      splashColor: Colors.transparent,
      hoverColor: Colors.transparent,
      highlightColor: Colors.transparent,
      child: Container(
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: isActive ? const Color(0xFF0C8CE9) : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Text(
          label,
          style: GoogleFonts.inter(
            fontSize: 14,
            fontWeight: isActive ? FontWeight.w600 : FontWeight.w500,
            color: isActive ? const Color(0xFF0C8CE9) : const Color(0xFF858585),
            height: 20 / 14,
          ),
        ),
      ),
    );
  }

  Widget _buildSelectedTabContent({required bool isCompact}) {
    switch (_selectedTab) {
      case _HelpTab.calculationMethods:
        return _buildCalculationMethodsCard();
      case _HelpTab.indicators:
        return _buildIndicatorsContent(isCompact: isCompact);
      case _HelpTab.contact:
        return _buildContactContent(isCompact: isCompact);
    }
  }

  Widget _buildCalculationMethodsCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: _cardDecoration,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Formulas',
            style: GoogleFonts.inter(
              fontSize: 20,
              fontWeight: FontWeight.w600,
              color: Colors.black,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'View the formulas and calculation logic used in this application',
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.w400,
              color: Colors.black.withValues(alpha: 0.8),
            ),
          ),
          const SizedBox(height: 24),
          _buildFormulaBand('A'),
          const SizedBox(height: 16),
          _buildFractionFormula(
            index: 'i',
            label: 'All-in Cost (₹ / sqft)',
            numerator: 'Total Expenses',
            denominator: 'Approved Selling Area',
          ),
          const SizedBox(height: 16),
          _buildFractionFormula(
            index: 'ii',
            label: 'Average Sales Price (₹ / sqft)',
            numerator: 'Total Sales Price',
            denominator: 'No. of Plot Sold',
          ),
          const SizedBox(height: 20),
          _buildFormulaBand('G'),
          const SizedBox(height: 16),
          _buildExpressionFormula(
            index: 'iii',
            expression: 'Gross Profit = Total Sales Value - Total Expenses',
          ),
          const SizedBox(height: 20),
          _buildFormulaBand('N'),
          const SizedBox(height: 16),
          _buildExpressionFormula(
            index: 'iv',
            expression:
                'Net Profit = Total Sales Value - Total Expenses - Total Compensation',
          ),
          const SizedBox(height: 20),
          _buildFormulaBand('P'),
          const SizedBox(height: 16),
          _buildFractionFormula(
            index: 'v',
            label: 'Profit Margin (%)',
            numerator: 'Net Profit',
            denominator: 'Total Sales Value',
            showTimes100: true,
          ),
          const SizedBox(height: 20),
          _buildFormulaBand('R'),
          const SizedBox(height: 16),
          _buildFractionFormula(
            index: 'vi',
            label: 'ROI (%)',
            numerator: 'Net Profit',
            denominator: 'Total Expenses',
            showTimes100: true,
          ),
        ],
      ),
    );
  }

  Widget _buildFormulaBand(String title) {
    return Container(
      width: double.infinity,
      color: const Color(0xFFCFCFCF),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Text(
        title,
        style: GoogleFonts.inter(
          fontSize: 14,
          fontWeight: FontWeight.w700,
          color: Colors.black,
        ),
      ),
    );
  }

  Widget _buildFormulaText(String value) {
    return Text(
      value,
      style: GoogleFonts.inter(
        fontSize: 14,
        fontWeight: FontWeight.w400,
        color: Colors.black,
      ),
    );
  }

  Widget _buildFractionFormula({
    required String index,
    required String label,
    required String numerator,
    required String denominator,
    bool showTimes100 = false,
  }) {
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _buildFormulaText('$index)'),
        _buildFormulaText(label),
        _buildFormulaText('='),
        _buildFraction(numerator: numerator, denominator: denominator),
        if (showTimes100) ...[
          _buildFormulaText('x'),
          _buildFormulaText('100'),
        ],
      ],
    );
  }

  Widget _buildExpressionFormula({
    required String index,
    required String expression,
  }) {
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _buildFormulaText('$index)'),
        _buildFormulaText(expression),
      ],
    );
  }

  Widget _buildFraction({
    required String numerator,
    required String denominator,
  }) {
    return IntrinsicWidth(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildFormulaText(numerator),
          const SizedBox(height: 2),
          Container(
            width: double.infinity,
            height: 0.5,
            color: Colors.black,
          ),
          const SizedBox(height: 2),
          _buildFormulaText(denominator),
        ],
      ),
    );
  }

  Widget _buildIndicatorsContent({required bool isCompact}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: isCompact ? double.infinity : 760,
          ),
          child: _buildIconIndicatorsCard(),
        ),
        const SizedBox(height: 36),
        ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: isCompact ? double.infinity : 540,
          ),
          child: _buildStatusIndicatorsCard(),
        ),
      ],
    );
  }

  Widget _buildIconIndicatorsCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: _cardDecoration,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Icon Indicators',
            style: GoogleFonts.inter(
              fontSize: 20,
              fontWeight: FontWeight.w600,
              color: Colors.black,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Describes system alerts and warnings displayed in this application.',
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.w400,
              color: Colors.black.withValues(alpha: 0.8),
            ),
          ),
          const SizedBox(height: 24),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildFormulaText('i)'),
              const SizedBox(width: 8),
              Expanded(
                child: Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    _buildFormulaText('Needs attention (optional)'),
                    SvgPicture.asset(
                      'assets/images/Warning.svg',
                      width: 16,
                      height: 16,
                      fit: BoxFit.contain,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            "Check this field. Something may need attention, but it's not required.",
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.w400,
              color: Colors.black.withValues(alpha: 0.8),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Example:',
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.w400,
              color: Colors.black.withValues(alpha: 0.8),
            ),
          ),
          const SizedBox(height: 8),
          _buildSampleField(
            hintText: 'Name displayed on report cover.',
            shadowColor: const Color(0xFFFFFB00),
          ),
          const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildFormulaText('ii)'),
              const SizedBox(width: 8),
              Expanded(
                child: Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    _buildFormulaText('Required field / Danger Field'),
                    SvgPicture.asset(
                      'assets/images/Error_msg.svg',
                      width: 16,
                      height: 14,
                      fit: BoxFit.contain,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'This field requires attention. It may be empty, invalid, or contain important information that should be reviewed or completed.',
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.w400,
              color: Colors.black.withValues(alpha: 0.8),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Example:',
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.w400,
              color: Colors.black.withValues(alpha: 0.8),
            ),
          ),
          const SizedBox(height: 8),
          _buildSampleField(
            hintText: 'Enter Expense Item',
            shadowColor: const Color(0xFFFF0000).withValues(alpha: 0.5),
          ),
        ],
      ),
    );
  }

  Widget _buildSampleField({
    required String hintText,
    required Color shadowColor,
  }) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 304),
      child: Container(
        width: double.infinity,
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        alignment: Alignment.centerLeft,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
          boxShadow: [
            BoxShadow(
              color: shadowColor,
              blurRadius: 2,
              offset: const Offset(0, 0),
            ),
          ],
        ),
        child: Text(
          hintText,
          style: GoogleFonts.inter(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            color: const Color(0xFFADADAD).withValues(alpha: 0.75),
          ),
        ),
      ),
    );
  }

  Widget _buildStatusIndicatorsCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: _cardDecoration,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Status Indicators',
            style: GoogleFonts.inter(
              fontSize: 20,
              fontWeight: FontWeight.w600,
              color: Colors.black,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Displays whether your changes are saved, in progress, or waiting due to network issues.',
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.w400,
              color: Colors.black.withValues(alpha: 0.8),
            ),
          ),
          const SizedBox(height: 24),
          _buildStatusItem(
            index: 'i)',
            statusWidget: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Saving...',
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w400,
                    color: const Color(0xFF0C8CE9),
                  ),
                ),
                Text(
                  'Please keep this page open',
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w400,
                    color: const Color(0xFF5C5C5C),
                  ),
                ),
              ],
            ),
            description:
                'Your changes are currently being saved. Please keep this page open.',
          ),
          const SizedBox(height: 16),
          _buildStatusItem(
            index: 'ii)',
            statusWidget: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Saved ✓',
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w400,
                    color: const Color(0xFF06AB00),
                  ),
                ),
                Text(
                  '2 minutes ago',
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w400,
                    color: const Color(0xFF5C5C5C),
                  ),
                ),
              ],
            ),
            description: 'Your changes have been successfully saved.',
          ),
          const SizedBox(height: 16),
          _buildStatusItem(
            index: 'iii)',
            statusWidget: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      "Couldn't save",
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.w400,
                        color: const Color(0xFFFF0000),
                      ),
                    ),
                    Text(
                      'waiting for network',
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.w400,
                        color: const Color(0xFF5C5C5C),
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: 16),
                const Icon(
                  Icons.refresh,
                  size: 16,
                  color: Color(0xFF404040),
                ),
              ],
            ),
            description:
                'Changes could not be saved due to network issues. Please check your connection.',
          ),
          const SizedBox(height: 16),
          Text(
            'Please do not close page while changes are being saved, or your data may be lost.',
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: Colors.black.withValues(alpha: 0.8),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusItem({
    required String index,
    required Widget statusWidget,
    required String description,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildFormulaText(index),
            const SizedBox(width: 8),
            Expanded(child: statusWidget),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          description,
          style: GoogleFonts.inter(
            fontSize: 14,
            fontWeight: FontWeight.w400,
            color: Colors.black.withValues(alpha: 0.8),
          ),
        ),
      ],
    );
  }

  Widget _buildContactContent({required bool isCompact}) {
    return Align(
      alignment: Alignment.centerLeft,
      child: SizedBox(
        width: isCompact ? null : 591,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: _cardDecoration,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Contact Support',
                style: GoogleFonts.inter(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                  color: Colors.black,
                ),
              ),
              const SizedBox(height: 8),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Get help, report issues, or share feedback. Reach us at',
                      maxLines: 1,
                      softWrap: false,
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.w400,
                        color: Colors.black.withValues(alpha: 0.8),
                      ),
                    ),
                    const SizedBox(width: 8),
                    InkWell(
                      onTap: _openSupportEmailCompose,
                      child: Text(
                        _supportEmail,
                        maxLines: 1,
                        softWrap: false,
                        style: GoogleFonts.inter(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: const Color(0xFF0C8CE9),
                          decoration: TextDecoration.underline,
                          decorationColor: const Color(0xFF0C8CE9),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Container(
                height: 40,
                padding: const EdgeInsets.only(left: 8),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.95),
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.25),
                      blurRadius: 2,
                      offset: const Offset(0, 0),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _supportEmail,
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: Colors.black,
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 30.4,
                      height: 40,
                      child: InkWell(
                        onTap: _copySupportEmail,
                        borderRadius: BorderRadius.circular(4),
                        child: const Icon(
                          Icons.content_copy_outlined,
                          size: 16,
                          color: Color(0xFF0C8CE9),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
