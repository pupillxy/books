import 'package:flutter/material.dart';

/// 「墨笺」设计语言全局 Token（来源：docs/ui-design-spec.md）
class MoStyle {
  MoStyle._();

  // ---------- 亮色 ----------
  static const primary = Color(0xFFC2522C); // 朱砂棕
  static const primaryStrong = Color(0xFFA13F1E);
  static const primarySoft = Color(0xFFFBEAE1); // 主色淡底
  static const primaryAlpha = Color(0x24C2522C); // rgba(194,82,44,.14)
  static const accent2 = Color(0xFFB7846A);
  static const coral = Color(0xFFE06849);
  static const bg = Color(0xFFF7EFE6); // 暖纸色 App 背景
  static const panel = Color(0xFFFFFFFF);
  static const ink = Color(0xFF332417);
  static const ink2 = Color(0xFF54453A);
  static const muted = Color(0xFF8A7866);

  /// 正文主墨色（跟随深浅色：深色模式用亮墨，避免暗底暗字看不清）
  static Color inkOf(BuildContext context) =>
      Theme.of(context).colorScheme.brightness == Brightness.dark ? darkInk : ink;
  static const rule = Color(0xFFEADCCA);
  static const success = Color(0xFF1F9D6D);
  static const danger = Color(0xFFD84A44);
  static const star = Color(0xFFF0A23A);
  static const focusShadow = Color(0x29C2522C); // rgba(194,82,44,.16)
  static const btnGradientStart = Color(0xFFD46A3D);

  // ---------- 暗色 ----------
  static const darkPrimary = Color(0xFFE0794C);
  static const darkPrimaryStrong = Color(0xFFE5865E);
  static const darkPrimarySoft = Color(0xFF2B211B);
  static const darkBg = Color(0xFF15181F);
  static const darkPanel = Color(0xFF1D212A);
  static const darkInk = Color(0xFFE7E8EC);
  static const darkInk2 = Color(0xFFC2C6CF);
  static const darkMuted = Color(0xFF9AA0AB);
  static const darkRule = Color(0xFF2E3440);
  static const darkInputFill = Color(0xFF23262F);
  static const darkInputBorder = Color(0xFF333B48);

  // ---------- 字体 ----------
  static const titleFont = 'serif'; // 标题/书名衬线

  // ---------- 阴影 ----------
  static List<BoxShadow> shadowSm(Color c) => [
        BoxShadow(color: c.withValues(alpha: 0.07), blurRadius: 14, offset: const Offset(0, 3)),
      ];
  static List<BoxShadow> shadowMd(Color c) => [
        BoxShadow(color: c.withValues(alpha: 0.11), blurRadius: 30, offset: const Offset(0, 10)),
      ];
  static List<BoxShadow> shadowBtn() => const [
        BoxShadow(color: Color(0x57C2522C), blurRadius: 22, offset: Offset(0, 10)), // .34
      ];

  // ---------- 品牌渐变 ----------
  /// 朱砂三段渐变（续读卡 / 书城焦点卡），搭配右上半透明白圆
  static const brandGradient = LinearGradient(
    begin: Alignment(-0.6, -1), // ≈115deg
    end: Alignment(0.6, 1),
    stops: [0, 0.62, 1],
    colors: [Color(0xFFCF6334), Color(0xFFC2522C), Color(0xFFDD8A5A)],
  );

  /// 登录页整页渐变
  static const pageGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    stops: [0, 0.46, 1],
    colors: [Color(0xFFF4DCC3), Color(0xFFF9EADA), Color(0xFFFDF7F1)],
  );

  /// 主按钮渐变
  static const btnGradient = LinearGradient(
    begin: Alignment(-0.7, -1), // ≈135deg
    end: Alignment(0.7, 1),
    colors: [Color(0xFFD46A3D), Color(0xFFC2522C)],
  );

  /// 详情页封面区渐变
  static const detailHeaderGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    stops: [0, 0.55, 1],
    colors: [Color(0xFFF7E6D6), Color(0xFFF3DCC6), Color(0xFFF6E4E0)],
  );

  /// 无封面占位渐变色板（title.hashCode 选色）
  static const coverGradients = <List<Color>>[
    [Color(0xFF5B6BCD), Color(0xFF3B4A97)],
    [Color(0xFF2AA39A), Color(0xFF16756E)],
    [Color(0xFF8A6ED8), Color(0xFF5C46A8)],
    [Color(0xFFE08A52), Color(0xFFC0622F)],
    [Color(0xFFD46C9A), Color(0xFFA84472)],
    [Color(0xFF4AA877), Color(0xFF2D7C52)],
  ];
}

/// 亮色主题
ThemeData moLightTheme() {
  const s = MoStyle.primary;
  final base = ColorScheme.light(
    primary: s,
    onPrimary: Colors.white,
    primaryContainer: MoStyle.primarySoft,
    onPrimaryContainer: MoStyle.primaryStrong,
    secondary: MoStyle.accent2,
    onSecondary: Colors.white,
    surface: MoStyle.panel,
    onSurface: MoStyle.ink,
    onSurfaceVariant: MoStyle.ink2,
    outline: MoStyle.muted,
    outlineVariant: MoStyle.rule,
    error: MoStyle.danger,
    onError: Colors.white,
  );
  return _moTheme(base, Brightness.light);
}

/// 暗色主题
ThemeData moDarkTheme() {
  const s = MoStyle.darkPrimary;
  final base = ColorScheme.dark(
    primary: s,
    onPrimary: Color(0xFF2B1408),
    primaryContainer: MoStyle.darkPrimarySoft,
    onPrimaryContainer: MoStyle.darkPrimaryStrong,
    secondary: MoStyle.accent2,
    onSecondary: Color(0xFF2B1408),
    surface: MoStyle.darkPanel,
    onSurface: MoStyle.darkInk,
    onSurfaceVariant: MoStyle.darkInk2,
    outline: MoStyle.darkMuted,
    outlineVariant: MoStyle.darkRule,
    error: MoStyle.danger,
    onError: Colors.white,
  );
  return _moTheme(base, Brightness.dark);
}

ThemeData _moTheme(ColorScheme cs, Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final bg = dark ? MoStyle.darkBg : MoStyle.bg;
  final isLightScheme = cs.brightness == Brightness.light;
  final primary = isLightScheme ? MoStyle.primary : MoStyle.darkPrimary;
  final inputFill = dark ? MoStyle.darkInputFill : Colors.white;
  final inputBorder = dark ? MoStyle.darkInputBorder : MoStyle.rule;

  return ThemeData(
    useMaterial3: true,
    colorScheme: cs,
    scaffoldBackgroundColor: bg,
    splashFactory: InkSparkle.splashFactory,
    fontFamily: null, // 正文无衬线（系统默认 PingFang/Roboto）
    dividerColor: cs.outlineVariant,
    // 页面大标题：衬线加粗
    appBarTheme: AppBarTheme(
      backgroundColor: bg,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      iconTheme: IconThemeData(color: cs.onSurface),
      titleTextStyle: TextStyle(
        fontFamily: MoStyle.titleFont,
        fontSize: 23,
        fontWeight: FontWeight.w800,
        color: cs.onSurface,
      ),
    ),
    // 输入框：圆角 13 + 淡边
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: inputFill,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      hintStyle: TextStyle(color: cs.outline, fontSize: 13.5),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(13),
        borderSide: BorderSide(color: inputBorder),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(13),
        borderSide: BorderSide(color: inputBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(13),
        borderSide: BorderSide(color: primary, width: 1.6),
      ),
    ),
    // 按钮
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: primary,
        foregroundColor: cs.onPrimary,
        minimumSize: const Size(0, 48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: primary,
        minimumSize: const Size(0, 44),
        side: BorderSide(color: primary.withValues(alpha: 0.55), width: 1.4),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: primary,
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
    ),
    // 底部导航：高 58、顶 1px rule
    navigationBarTheme: NavigationBarThemeData(
      height: 62,
      backgroundColor: dark ? MoStyle.darkPanel : const Color(0xFFFBFDFF),
      surfaceTintColor: Colors.transparent,
      indicatorColor: Colors.transparent,
      elevation: 0,
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return TextStyle(
          fontSize: 10.5,
          fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
          color: selected ? primary : cs.outline,
        );
      }),
      iconTheme: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return IconThemeData(
          size: 22,
          color: selected ? primary : cs.outline,
        );
      }),
    ),
    // 胶囊 Chip
    chipTheme: ChipThemeData(
      backgroundColor: isLightScheme ? MoStyle.primaryAlpha : MoStyle.darkPrimarySoft,
      labelStyle: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant),
      side: BorderSide.none,
      shape: const StadiumBorder(),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    ),
    // 卡片
    cardTheme: CardThemeData(
      elevation: 0,
      color: cs.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      margin: EdgeInsets.zero,
    ),
    // 弹窗
    dialogTheme: DialogThemeData(
      backgroundColor: cs.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      titleTextStyle: TextStyle(
        fontFamily: MoStyle.titleFont,
        fontSize: 17,
        fontWeight: FontWeight.w800,
        color: cs.onSurface,
      ),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      showDragHandle: true,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
    ),
    // Toast：黑胶囊白字
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: dark ? const Color(0xFF2A2F3A) : const Color(0xE6140F0C),
      contentTextStyle: const TextStyle(color: Colors.white, fontSize: 12.5),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
    ),
    // Tab 下划线（详情页/书城分类）
    tabBarTheme: TabBarThemeData(
      labelColor: primary,
      unselectedLabelColor: cs.outline,
      labelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
      unselectedLabelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      indicatorSize: TabBarIndicatorSize.tab,
      dividerColor: Colors.transparent,
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: primary),
  );
}
