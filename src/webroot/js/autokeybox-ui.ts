import { cfgGet, cfgSet } from './cfg.js';
import { getTranslation } from './i18n.js';
import { wireRowDialog } from './toggles.js';
import { openSubPage } from './subpage.js';

const t = (key: string, fallback: string): string => getTranslation(key) || fallback;

const HOURS_TO_SECONDS = 3600;
const DEFAULT_HOURS = 6;

export function openAutokeyboxDialog() {
  openSubPage({
    id: 'autokeybox',
    title: t('autokeybox_title', 'Auto Keybox'),
    description: t('autokeybox_guarded_desc', 'Checks the installed keybox and replaces it only when needed and a verified replacement is available.'),
    masterToggle: {
      key: 'toggle_autokeybox',
      defaultVal: '0',
      title: t('control_toggle_autokeybox_master', 'Use Auto Keybox'),
      syncSwitchId: 'toggle-background_autokeybox',
    },
    groups: [
      {
        items: [
          {
            type: 'input',
            id: 'ak-interval',
            title: t('autokeybox_interval', 'Interval (hours)'),
            description: t('autokeybox_guarded_interval_desc', 'How often to check the keybox. Default 6 hours.'),
            inputType: 'number',
            min: 1,
            unit: 'hrs',
            getValue: async () => {
              const raw = await cfgGet('autokeybox_interval', String(DEFAULT_HOURS * HOURS_TO_SECONDS));
              return String(Math.round(parseInt(raw || String(DEFAULT_HOURS * HOURS_TO_SECONDS), 10) / HOURS_TO_SECONDS) || DEFAULT_HOURS);
            },
            onChange: (val) => {
              const num = parseInt(val || String(DEFAULT_HOURS), 10);
              cfgSet('autokeybox_interval', String(Math.max(1, num) * HOURS_TO_SECONDS));
            },
          },
        ],
      },
    ],
  });
}

export function wireAutokeybox() {
  wireRowDialog('toggle-background_autokeybox-row', openAutokeyboxDialog);
}
