import { describe, expect, it, beforeEach, vi } from 'vitest'
import { cfgGet, cfgSet, cfgInvalidate, setDataDir, migrateLocalStorage } from './cfg.js'

import { exec } from './bridge.js'
import { showToast } from './toast.js'

vi.mock('./toast.js', () => ({ showToast: vi.fn() }))

vi.mock('./bridge.js', () => ({
  exec: vi.fn(() => Promise.resolve({ stdout: '', stderr: '', code: 0 })),
}))

beforeEach(() => {
  vi.clearAllMocks()
  setDataDir('/data/adb/specter')
  cfgInvalidate()
  localStorage.clear()
})

describe('cfg (caching layer)', () => {
  it('cfgGet returns cached value after cfgSet', async () => {
    cfgSet('test_key', 'test_value')
    const val = await cfgGet('test_key')
    expect(val).toBe('test_value')
  })

  it('cfgSet overwrites existing value', async () => {
    cfgSet('test_key', 'first')
    cfgSet('test_key', 'second')
    const val = await cfgGet('test_key')
    expect(val).toBe('second')
  })

  it('cfgGet returns defaultValue when not cached', async () => {
    const val = await cfgGet('nonexistent', 'default')
    expect(val).toBe('default')
  })

  it('cfgGet returns undefined when key missing and no default', async () => {
    const val = await cfgGet('nonexistent')
    expect(val).toBeUndefined()
  })

  it('cfgInvalidate removes single key', async () => {
    cfgSet('temp', 'value')
    expect(await cfgGet('temp')).toBe('value')
    cfgInvalidate('temp')
    expect(await cfgGet('temp')).toBeUndefined()
  })

  it('cfgInvalidate with no args clears all cache', async () => {
    cfgSet('a', '1')
    cfgSet('b', '2')
    cfgInvalidate()
    expect(await cfgGet('a')).toBeUndefined()
    expect(await cfgGet('b')).toBeUndefined()
  })

  it('reports a rejected device write and lets the same value retry', async () => {
    vi.mocked(exec).mockResolvedValueOnce({ stdout: '', stderr: 'Permission denied', code: 1 })

    expect(await cfgSet('theme', 'dark')).toBe(false)
    await vi.waitFor(() => expect(showToast).toHaveBeenCalledWith('Failed to save', { type: 'error' }))
    expect(localStorage.getItem('sp_cfg_theme')).toBeNull()

    expect(await cfgSet('theme', 'dark')).toBe(true)
    expect(localStorage.getItem('sp_cfg_theme')).toBe('dark')
    expect(exec).toHaveBeenCalledTimes(2)
  })

  it('migrateLocalStorage migrates keys', async () => {
    localStorage.setItem('selectedLanguage', 'en')
    localStorage.setItem('themeMode', 'dark')
    await migrateLocalStorage()
    expect(await cfgGet('lang')).toBe('en')
    expect(await cfgGet('theme')).toBe('dark')
    expect(localStorage.getItem('_cfg_migrated')).toBe('1')
  })

  it('migrateLocalStorage only runs once', async () => {
    localStorage.setItem('selectedLanguage', 'en')
    await migrateLocalStorage()
    localStorage.setItem('selectedLanguage', 'fr')
    await migrateLocalStorage()
    expect(await cfgGet('lang')).toBe('en')
  })
})
