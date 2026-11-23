import { describe, expect, it, beforeEach, vi } from 'vitest'
import { initTheme, applyPreset, getCurrentPreset } from './theme.js'
import { cfgGet, cfgSet, cfgInvalidate, cfgInit, setDataDir } from './cfg.js'

vi.mock('./bridge.js', () => ({
  exec: vi.fn(() => Promise.resolve({ stdout: '', stderr: '', code: 0 })),
}))

beforeEach(() => {
  vi.clearAllMocks()
  setDataDir('/data/adb/specter')
  cfgInvalidate()
  localStorage.clear()
  document.documentElement.removeAttribute('data-theme')
  document.documentElement.removeAttribute('data-theme-preset')
  document.documentElement.removeAttribute('data-theme-resolved')
})

describe('theme persistence', () => {
  it('applyPreset("monet") persists theme_preset as monet and theme_monet_switch as 1', async () => {
    applyPreset('monet')
    expect(getCurrentPreset()).toBe('monet')
    expect(await cfgGet('theme_preset')).toBe('monet')
    expect(await cfgGet('theme_monet_switch')).toBe('1')
    expect(document.documentElement.getAttribute('data-theme-preset')).toBe('monet')
  })

  it('applyPreset("red") persists theme_preset as red and theme_monet_switch as 0', async () => {
    applyPreset('red')
    expect(getCurrentPreset()).toBe('red')
    expect(await cfgGet('theme_preset')).toBe('red')
    expect(await cfgGet('theme_monet_switch')).toBe('0')
    expect(await cfgGet('theme_fixed_preset')).toBe('red')
    expect(document.documentElement.getAttribute('data-theme-preset')).toBe('red')
  })

  it('re-entering web UI with theme_monet_switch=1 restores monet preset permanently', async () => {
    // User had a fixed preset first
    applyPreset('blue')
    expect(await cfgGet('theme_monet_switch')).toBe('0')

    // User enables dynamic color scheme
    applyPreset('monet')
    expect(await cfgGet('theme_monet_switch')).toBe('1')
    expect(await cfgGet('theme_preset')).toBe('monet')

    await vi.waitFor(() => expect(localStorage.getItem('sp_cfg_theme_monet_switch')).toBe('1'))
    // Simulate leaving and re-entering the Web UI (fresh page reload)
    cfgInvalidate()
    await cfgInit()
    // Config values are preserved from localStorage
    expect(await cfgGet('theme_monet_switch')).toBe('1')

    await initTheme('dark')
    expect(getCurrentPreset()).toBe('monet')
    expect(document.documentElement.getAttribute('data-theme-preset')).toBe('monet')
  })

  it('re-entering web UI with theme_monet_switch=0 restores fixed preset', async () => {
    // User disables dynamic color scheme and chooses yellow
    await cfgSet('theme_monet_switch', '0')
    await cfgSet('theme_fixed_preset', 'yellow')
    await cfgSet('theme_preset', 'yellow')

    // Simulate leaving and re-entering the Web UI
    cfgInvalidate()
    await cfgInit()
    await initTheme('dark')
    expect(getCurrentPreset()).toBe('yellow')
    expect(document.documentElement.getAttribute('data-theme-preset')).toBe('yellow')
  })
})
