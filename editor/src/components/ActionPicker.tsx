import { useEffect, useId, useMemo, useRef, useState } from 'react'
import type { KeyboardEvent as ReactKeyboardEvent } from 'react'
import { CheckIcon, ChevronDownIcon, MagnifyingGlassIcon } from '@radix-ui/react-icons'

export interface ActionPickerOption {
  value: string
  label: string
  detail?: string
  group: string
  keywords?: string
}

interface ActionPickerProps {
  id: string
  label: string
  value: string
  options: ActionPickerOption[]
  onChange: (value: string) => void
  describedBy?: string
  disabled?: boolean
}

function searchRank(option: ActionPickerOption, query: string): number {
  if (!query) return 0
  const label = option.label.toLocaleLowerCase()
  const value = option.value.toLocaleLowerCase()
  const text = `${label} ${value} ${option.detail ?? ''} ${option.group} ${option.keywords ?? ''}`.toLocaleLowerCase()
  if (label === query || value === query) return 0
  if (label.startsWith(query) || value.startsWith(query)) return 1
  if (text.split(/\s+/).some((word) => word.startsWith(query))) return 2
  if (text.includes(query)) return 3
  return -1
}

export function ActionPicker({ id, label, value, options, onChange, describedBy, disabled }: ActionPickerProps) {
  const reactId = useId().replace(/:/g, '')
  const listboxId = `${id}-${reactId}-listbox`
  const searchId = `${id}-${reactId}-search`
  const rootRef = useRef<HTMLDivElement>(null)
  const triggerRef = useRef<HTMLButtonElement>(null)
  const searchRef = useRef<HTMLInputElement>(null)
  const [open, setOpen] = useState(false)
  const [query, setQuery] = useState('')
  const [activeIndex, setActiveIndex] = useState(0)

  const selected = options.find((option) => option.value === value)
  const filtered = useMemo(() => {
    const normalized = query.trim().toLocaleLowerCase()
    return options
      .map((option, index) => ({ option, index, rank: searchRank(option, normalized) }))
      .filter((item) => item.rank >= 0)
      .sort((a, b) => a.rank - b.rank || a.index - b.index)
      .map((item) => item.option)
  }, [options, query])

  useEffect(() => {
    if (!open) return
    setActiveIndex(Math.max(0, filtered.findIndex((option) => option.value === value)))
  }, [filtered, open, value])

  useEffect(() => {
    if (!open) return
    requestAnimationFrame(() => searchRef.current?.focus())
    const closeOnOutsidePointer = (event: PointerEvent) => {
      if (!rootRef.current?.contains(event.target as Node)) setOpen(false)
    }
    document.addEventListener('pointerdown', closeOnOutsidePointer)
    return () => document.removeEventListener('pointerdown', closeOnOutsidePointer)
  }, [open])

  const close = (returnFocus = false) => {
    setOpen(false)
    setQuery('')
    if (returnFocus) triggerRef.current?.focus()
  }

  const select = (option: ActionPickerOption) => {
    onChange(option.value)
    close(true)
  }

  const openPicker = (initialQuery = '') => {
    if (disabled) return
    setQuery(initialQuery)
    setOpen(true)
  }

  const handleListKeyDown = (event: ReactKeyboardEvent<HTMLInputElement>) => {
    if (event.key === 'Escape') {
      event.preventDefault()
      close(true)
      return
    }
    if (event.key === 'Tab') {
      close(false)
      return
    }
    if (filtered.length === 0) return
    if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
      event.preventDefault()
      const direction = event.key === 'ArrowDown' ? 1 : -1
      setActiveIndex((current) => (current + direction + filtered.length) % filtered.length)
      return
    }
    if (event.key === 'Home' || event.key === 'End') {
      event.preventDefault()
      setActiveIndex(event.key === 'Home' ? 0 : filtered.length - 1)
      return
    }
    if (event.key === 'Enter') {
      event.preventDefault()
      const option = filtered[activeIndex]
      if (option) select(option)
    }
  }

  const grouped = filtered.reduce<Array<{ name: string; options: ActionPickerOption[] }>>((result, option) => {
    const group = result.find((item) => item.name === option.group)
    if (group) group.options.push(option)
    else result.push({ name: option.group, options: [option] })
    return result
  }, [])

  return (
    <div ref={rootRef} className="action-picker">
      <button
        ref={triggerRef}
        id={id}
        type="button"
        role="combobox"
        className="action-picker-trigger"
        aria-label={label}
        aria-expanded={open}
        aria-controls={listboxId}
        aria-haspopup="listbox"
        aria-describedby={describedBy}
        disabled={disabled}
        onClick={() => open ? close(false) : openPicker()}
        onKeyDown={(event) => {
          if (event.key === 'ArrowDown' || event.key === 'ArrowUp' || event.key === 'Enter' || event.key === ' ') {
            event.preventDefault()
            openPicker()
            return
          }
          if (event.key.length === 1 && !event.metaKey && !event.ctrlKey && !event.altKey) {
            event.preventDefault()
            openPicker(event.key)
          }
        }}
      >
        <span className="action-picker-value"><strong>{selected?.label ?? (value || 'Choose an action')}</strong>{selected?.detail && <small>{selected.detail}</small>}</span>
        <ChevronDownIcon aria-hidden="true" />
      </button>

      {open && (
        <div className="action-picker-popover">
          <label className="action-picker-search" htmlFor={searchId}>
            <MagnifyingGlassIcon aria-hidden="true" />
            <span className="sr-only">Search {label.toLocaleLowerCase()}</span>
            <input
              ref={searchRef}
              id={searchId}
              type="search"
              role="searchbox"
              value={query}
              aria-label={`Search ${label.toLocaleLowerCase()}`}
              aria-controls={listboxId}
              aria-activedescendant={filtered[activeIndex] ? `${listboxId}-option-${filtered[activeIndex].value.replace(/[^a-zA-Z0-9_-]/g, '-')}` : undefined}
              placeholder="Search actions"
              onChange={(event) => {
                setQuery(event.target.value)
                setActiveIndex(0)
              }}
              onKeyDown={handleListKeyDown}
            />
          </label>
          <div id={listboxId} className="action-picker-list" role="listbox" aria-label={`${label} choices`}>
            {grouped.map((group) => (
              <div key={group.name} className="action-picker-group" role="group" aria-label={group.name}>
                <div className="action-picker-group-label">{group.name}</div>
                {group.options.map((option) => {
                  const index = filtered.indexOf(option)
                  const selectedOption = option.value === value
                  const active = index === activeIndex
                  const optionId = `${listboxId}-option-${option.value.replace(/[^a-zA-Z0-9_-]/g, '-')}`
                  return (
                    <button
                      key={`${group.name}-${option.value}`}
                      id={optionId}
                      type="button"
                      role="option"
                      className={active ? 'action-picker-option is-active' : 'action-picker-option'}
                      aria-selected={selectedOption}
                      onMouseMove={() => setActiveIndex(index)}
                      onMouseDown={(event) => event.preventDefault()}
                      onClick={() => select(option)}
                    >
                      <span><strong>{option.label}</strong>{option.detail && <small>{option.detail}</small>}</span>
                      {selectedOption && <CheckIcon aria-hidden="true" />}
                    </button>
                  )
                })}
              </div>
            ))}
            {filtered.length === 0 && <div className="action-picker-empty" role="status">No matching actions</div>}
          </div>
        </div>
      )}
    </div>
  )
}
