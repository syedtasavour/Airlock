// Builds terminal/Airlock.terminal — your kitty typography, translated to
// macOS Terminal.app and sized for this Mac's screen. Run:
//   osascript -l JavaScript terminal/make-profile.js [base-profile] [font-size]
// then `open terminal/Airlock.terminal` to import it.
//
// kitty (Arch)                         -> Terminal.app (here)
//   JetBrainsMono Nerd Font 12pt       -> JetBrainsMono NF 13pt (Retina 15": 12 reads small)
//   modify_font cell_height 115%       -> line spacing 1.15
//   cursor_shape beam                  -> vertical-bar cursor
//   background_opacity 0.85 + blur     -> base profile's translucency + background blur
//   enable_audio_bell no / visual 0    -> both bells off
//   scrollback_lines 10000             -> 10,000-line scrollback
//   (zsh needs it)                     -> Option key acts as Meta (Option-←/→ = word jumps)
//   window size                        -> 140x38: the status line's limits fit on one row (>=130 cols)
// No Terminal.app equivalent: ligatures, window padding, cursor trail, powerline tabs.
ObjC.import('Foundation');
ObjC.import('AppKit');

function run(argv) {
  const baseName = argv[0] || 'Clear Dark';
  const size = parseFloat(argv[1] || '13');
  const out = $.NSString.stringWithString(argv[2] || 'terminal/Airlock.terminal').stringByExpandingTildeInPath;

  const ud = $.NSUserDefaults.alloc.initWithSuiteName('com.apple.Terminal');
  const all = ud.dictionaryForKey('Window Settings');
  if (all.isNil()) throw new Error('no Terminal profiles found');
  const base = all.objectForKey(baseName);
  if (base.isNil()) throw new Error('profile not found: ' + baseName);
  const p = base.mutableCopy;

  const font = $.NSFont.fontWithNameSize('JetBrainsMonoNF-Regular', size);
  if (font.isNil()) throw new Error('JetBrainsMono NF is not installed (~/Library/Fonts)');
  const err = Ref();
  const fontData = $.NSKeyedArchiver.archivedDataWithRootObjectRequiringSecureCodingError(font, false, err);

  const num = (v) => $.NSNumber.numberWithDouble(v);
  const yes = $.NSNumber.numberWithBool(true), no = $.NSNumber.numberWithBool(false);
  const set = (k, v) => p.setObjectForKey(v, k);

  set('name', $('Airlock'));
  set('type', $('Window Settings'));
  set('ProfileCurrentVersion', num(2.07));
  set('Font', fontData);
  set('FontAntialias', yes);
  set('FontHeightSpacing', num(1.15));   // ~115% line height
  set('FontWidthSpacing', num(1.0));
  set('CursorType', $.NSNumber.numberWithInt(2));   // 0 block · 1 underline · 2 vertical bar (beam)
  set('CursorBlink', yes);
  set('Bell', no);
  set('VisualBell', no);
  set('VisualBellOnlyWhenMuted', no);
  set('useOptionAsMetaKey', yes);
  set('ShouldLimitScrollback', $.NSNumber.numberWithInt(1));
  set('ScrollbackLines', $.NSNumber.numberWithInt(10000));
  set('BackgroundBlur', num(0.5));
  set('columnCount', $.NSNumber.numberWithInt(140));
  set('rowCount', $.NSNumber.numberWithInt(38));
  set('shellExitAction', $.NSNumber.numberWithInt(1));   // close the window when the shell exits cleanly

  const ok = p.writeToFileAtomically(out, true);
  if (!ok) throw new Error('could not write ' + out.js);
  return 'wrote ' + out.js + ' (base: ' + baseName + ', JetBrainsMono NF ' + size + 'pt)';
}
