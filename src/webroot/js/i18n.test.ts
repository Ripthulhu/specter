import { afterEach, expect, it, vi } from 'vitest';
import { applyLanguage, getTranslation } from './i18n.js';

vi.mock('./cfg.js', () => ({ cfgSet: vi.fn() }));

afterEach(() => {
  vi.unstubAllGlobals();
  localStorage.clear();
});

it('ignores a stale language pack response after switching to English', async () => {
  let finish!: (response: unknown) => void;
  vi.stubGlobal('fetch', vi.fn(() => new Promise(resolve => { finish = resolve; })));
  const previous = applyLanguage('fr');
  await applyLanguage('en');
  finish({ ok: true, json: async () => ({ dialog_apply: 'Appliquer' }) });
  await previous;
  expect(getTranslation('dialog_apply')).toBe('Apply');
});

it('falls back to English when a different language pack is missing', async () => {
  vi.stubGlobal('fetch', vi.fn()
    .mockResolvedValueOnce({ ok: true, json: async () => ({ dialog_apply: 'Appliquer' }) })
    .mockResolvedValueOnce({ ok: false }));
  await applyLanguage('fr');
  expect(getTranslation('dialog_apply')).toBe('Appliquer');
  await applyLanguage('es');
  expect(getTranslation('dialog_apply')).toBe('Apply');
});
