vim9script

import './util.vim'
import './options.vim' as opt

# Open file "fname" in a suitable window.  If a window is already present, then
# jump to it.  Otherwise open a new one.
def OpenFileInWindow(fname: string)
  # If the file is already opened in a window, jump to it. Otherwise open it
  # in another window
  var wid: number = fname->bufwinid()
  if wid == -1
    # Find a window showing a normal buffer and use it
    for w in getwininfo()
      if w.winid->getwinvar('&buftype')->empty()
	wid = w.winid
	wid->win_gotoid()
	break
      endif
    endfor
    if wid == -1
      var symWinid: number = win_getid()
      :rightbelow vnew
      # retain the fixed symbol window width
      var winsz = opt.lspOptions.outlineWinSize
      win_execute(symWinid, $'vertical resize {winsz}')
    endif

    exe $'edit {fname}'
  else
    # Window already exists, just switch focus
    wid->win_gotoid()
  endif
enddef

# jump to a symbol selected in the outline window
def OutlineJumpToSymbol(stayInOutline: bool = false)
  var lnum: number = line('.') - 1

  var entry = w:lspSymbols.lnumTable->get(lnum, {})
  if entry->empty()
    return
  endif

  var slnum: number = entry.lnum
  var scol: number = entry.col
  var fname: string = w:lspSymbols.filename
  var outlineWinid = win_getid()

  # Highlight the selected symbol
  prop_remove({type: 'LspOutlineHighlight'})
  var col: number = getline('.')->match('\S') + 1
  prop_add(line('.'), col, {type: 'LspOutlineHighlight',
			length: entry.name->len()})

  # disable the outline window refresh
  skipRefresh = true

  try
    # Open the file
    OpenFileInWindow(fname)

    # Set the previous cursor location mark. Instead of using setpos(), m' is
    # used so that the current location is added to the jump list.
    :normal! m'

    # Jump to the symbol position
    [slnum, scol]->cursor()

    # If in preview mode, jump back to the outline window
    if stayInOutline
      normal! zz
      win_gotoid(outlineWinid)
    endif
  finally
    skipRefresh = false
  endtry
enddef

# Skip refreshing the outline window. Used to prevent recursive updates to the
# outline window
var skipRefresh: bool = false

export def SkipOutlineRefresh(): bool
  return skipRefresh
enddef

# Default icons displayed before the symbol kinds.  Only characters which are
# available in most fonts are used.  Can be overridden using the
# "outlineIcons" option.
const defaultKindIcons: dict<string> = {
  File: '▤',
  Module: '▣',
  Namespace: '◫',
  Package: '▦',
  Class: '◆',
  Method: 'ƒ',
  Property: '◇',
  Field: '▪',
  Constructor: '⊕',
  Enum: '∈',
  Interface: '◈',
  Function: 'ƒ',
  Variable: '◦',
  Constant: 'π',
  String: '"',
  Number: '#',
  Boolean: '◐',
  Array: '⊞',
  Object: '⊙',
  Key: 'κ',
  Null: '∅',
  EnumMember: '∙',
  Struct: '▱',
  Event: '↯',
  Operator: '±',
  TypeParameter: 'τ'
}

# Returns the icon to display before the symbol kind "kind".  Returns an empty
# string if icons are disabled or no icon is defined for the kind.
def KindIcon(kind: string): string
  if !opt.lspOptions.outlineShowIcons
    return ''
  endif
  return opt.lspOptions.outlineIcons->get(kind,
					   defaultKindIcons->get(kind, ''))
enddef

def AddSymbolText(bnr: number,
			symbolTypeTable: dict<list<dict<any>>>,
			pfx: string,
			text: list<string>,
			lnumMap: list<dict<any>>,
			kindProps: list<dict<any>>,
			children: bool)
  var prefix: string = pfx .. '  '
  for [symType, symbols] in symbolTypeTable->items()
    if !children
      # Add an empty line for the top level symbol types. For types in the
      # children symbols, don't add the empty line.
      text->extend([''])
      lnumMap->extend([{}])
    endif
    # Symbols are indented one level below their kind. Use a separate
    # variable so that the indentation doesn't grow with each kind.
    var symPrefix: string = prefix
    var kindIndent: string = ''
    if children
      kindIndent = prefix
      symPrefix ..= '  '
    endif
    # Display the kind icon and name followed by the number of symbols of
    # that kind
    var icon: string = KindIcon(symType)
    var iconText: string = icon->empty() ? '' : $'{icon} '
    var count: string = $'({symbols->len()})'
    text->add($'{kindIndent}{iconText}{symType} {count}')
    lnumMap->extend([{}])
    # remember the location of the icon, kind name and count to highlight them
    var iconCol: number = kindIndent->len() + 1
    if !icon->empty()
      kindProps->add({lnum: lnumMap->len(), col: iconCol,
		      length: icon->len(), type: 'LspOutlineIcon'})
    endif
    var kindCol: number = iconCol + iconText->len()
    kindProps->add({lnum: lnumMap->len(), col: kindCol,
		    length: symType->len(), type: 'LspOutlineKind'})
    kindProps->add({lnum: lnumMap->len(), col: kindCol + symType->len() + 1,
		    length: count->len(), type: 'LspOutlineCount'})
    for s in symbols
      text->add(symPrefix .. s.name)
      # remember the line number for the symbol
      var s_start = s.selectionRange.start
      var start_col: number = util.GetLineByteFromPos(bnr, s_start) + 1
      lnumMap->add({
	name: s.name,
	lnum: s_start.line + 1,
	col: start_col
      })
      s.outlineLine = lnumMap->len()
      if s->has_key('children') && !s.children->empty()
	AddSymbolText(bnr, s.children, symPrefix, text, lnumMap, kindProps,
		      true)
      endif
    endfor
  endfor
enddef

# update the symbols displayed in the outline window
export def UpdateOutlineWindow(fname: string,
				symbolTypeTable: dict<list<dict<any>>>,
				symbolLineTable: list<dict<any>>)
  var wid: number = bufwinid('LSP-Outline')
  if wid == -1
    return
  endif

  # stop refreshing the outline window recursively
  skipRefresh = true

  var prevWinID: number = win_getid()
  wid->win_gotoid()

  # if the file displayed in the outline window is same as the new file, then
  # save and restore the cursor position
  var symbols = wid->getwinvar('lspSymbols', {})
  var saveCursor: list<number> = []
  if !symbols->empty() && symbols.filename == fname
    saveCursor = getcurpos()
  endif

  :setlocal modifiable
  deletebufline('', 1, '$')

  # The first two lines in the buffer display the file name and the directory
  var fileIcon: string = KindIcon('File')
  var fileIconText: string = fileIcon->empty() ? '' : $'{fileIcon} '
  var fileText: string = fname->fnamemodify(':t')
  setline(1, [$'{fileIconText}{fileText}', fname->fnamemodify(':p:~:h')])
  if !fileIcon->empty()
    prop_add(1, 1, {type: 'LspOutlineIcon', length: fileIcon->len()})
  endif
  prop_add(1, fileIconText->len() + 1, {type: 'LspOutlineFile',
					length: fileText->len()})
  prop_add(2, 1, {type: 'LspOutlineInfo', length: getline(2)->len()})

  var lnumMap: list<dict<any>> = [{}, {}]
  var text: list<string> = []
  var kindProps: list<dict<any>> = []
  AddSymbolText(fname->bufnr(), symbolTypeTable, '', text, lnumMap,
		kindProps, false)
  if text->empty()
    # Let the user know that the file doesn't have any symbols
    var msg: string = 'No symbols found'
    text = ['', msg]
    kindProps->add({lnum: 4, col: 1, length: msg->len(),
		    type: 'LspOutlineInfo'})
  endif
  text->append('$')
  for p in kindProps
    prop_add(p.lnum, p.col, {type: p.type, length: p.length})
  endfor
  w:lspSymbols = {
    filename: fname,
    lnumTable: lnumMap,
    symbolsByLine: symbolLineTable
  }
  :setlocal nomodifiable

  if !saveCursor->empty()
    saveCursor->setpos('.')
  endif

  if exists('#User#LspOutlineUpdated')
    :doautocmd <nomodeline> User LspOutlineUpdated
  endif

  prevWinID->win_gotoid()

  # Highlight the current symbol
  OutlineHighlightCurrentSymbol()

  # re-enable refreshing the outline window
  skipRefresh = false
enddef

# Search for the symbol corresponding to the line 'lnum' in the symbol table.
# A symbol (e.g. a function) spans multiple lines.
def FindSymbolForLine(symbolTable: list<dict<any>>, lnum: number): number
  var left = 0
  var right = symbolTable->len() - 1
  var mid: number

  # binary search
  while left <= right
    mid = (left + right) / 2
    var r = symbolTable[mid].range
    if lnum >= (r.start.line + 1) && lnum <= (r.end.line + 1)
      # symbol found
      return mid
    endif
    if lnum > (r.start.line + 1)
      left = mid + 1
    else
      right = mid - 1
    endif
  endwhile

  # symbol not found
  if left > right
    return -1
  else
    return mid
  endif
enddef

def OutlineHighlightCurrentSymbol()
  var fname: string = expand('%')->fnamemodify(':p')
  if fname->empty() || &filetype->empty()
    return
  endif

  var wid: number = bufwinid('LSP-Outline')
  if wid == -1
    return
  endif

  # Check whether the symbols for this file are displayed in the outline
  # window
  var lspSymbols = wid->getwinvar('lspSymbols', {})
  if lspSymbols->empty() || lspSymbols.filename != fname
    return
  endif

  var symbolTable: list<dict<any>> = lspSymbols.symbolsByLine

  # line number to locate the symbol
  var lnum: number = line('.')

  # Find the symbol for the current line number
  var symIdx: number = FindSymbolForLine(symbolTable, lnum)

  # clear the highlighting in the outline window
  var bnr: number = wid->winbufnr()
  prop_remove({bufnr: bnr, type: 'LspOutlineHighlight'})

  if symIdx == -1
    # symbol not found
    return
  endif

  # Highlight the selected symbol
  var symbol: dict<any> = symbolTable[symIdx]
  var col: number =
    bnr->getbufline(symbol.outlineLine)->get(0, '')->match('\S') + 1
  prop_add(symbol.outlineLine, col, {bufnr: bnr, type: 'LspOutlineHighlight',
	   length: symbol.name->len()})

  # if the line is not visible, then scroll the outline window to make the
  # line visible
  var wininfo = wid->getwininfo()
  if symbol.outlineLine < wininfo[0].topline
      || symbol.outlineLine > wininfo[0].botline
    var cmd: string = $'call cursor({symbol.outlineLine}, 1) | normal! z.'
    win_execute(wid, cmd)
  endif
enddef

# Show the details of a symbol in the current line in the outline window
def OutlineShowSymbolDetail(lnum: number)
  var symbolTable: list<dict<any>> = w:lspSymbols.symbolsByLine
  if symbolTable->empty()
    return
  endif

  var idx = util.Indexof(symbolTable, (_, v) => v.outlineLine == lnum)
  if idx != -1
    echo $'{symbolTable[idx].name}: {symbolTable[idx].detail}'
  else
    echo ''
  endif
enddef

# when the outline window is closed, do the cleanup
def OutlineCleanup()
  # Remove the outline autocommands
  :silent! autocmd_delete([{group: 'LSPOutline'}])
enddef

# Toggle the outline window. Returns true if it opened the window, and false if it closed it.
export def ToggleOutlineWindow(cmdmods: string, winsize: number): bool
  var wid: number = bufwinid('LSP-Outline')
  if wid != -1
    win_execute(wid, ':q')
    return false
  endif
  Open(cmdmods, winsize)
  return true
enddef

# open the symbol outline window
export def OpenOutlineWindow(cmdmods: string, winsize: number)
  var wid: number = bufwinid('LSP-Outline')
  if wid == -1
    Open(cmdmods, winsize)
  endif
enddef

# close the symbol outline window
export def CloseOutlineWindow()
  var wid: number = bufwinid('LSP-Outline')
  if wid != -1
    win_execute(wid, ':q')
  endif
enddef

# Outline window zoom (maximize or minimize)
def ToggleOutlineZoom()
  # Use the user-defined option or the current width as the 'normal' size
  var normalWidth = opt.lspOptions.outlineWinSize
  var currentWidth = winwidth(0)

  # If currently at normal size (or smaller), zoom to max
  if currentWidth <= normalWidth
    w:lspOutlineWinWidth = currentWidth
    vertical resize
  else
    # If already zoomed, restore to original or default size
    var target = get(w:, 'lspOutlineWinWidth', normalWidth)
    exe $'vertical resize {target}'
  endif
enddef

# Set options to make the outline buffer as a scratch buffer
def SetOutlineBufferOptions()
  :setlocal buftype=nofile
  :setlocal bufhidden=delete
  :setlocal noswapfile nobuflisted
  :setlocal nonumber norelativenumber fdc=0 nowrap winfixheight winfixwidth
  :setlocal undolevels=-1
  :setlocal shiftwidth=2
  :setlocal foldenable
  :setlocal foldcolumn=1
  :setlocal foldlevel=4
  :setlocal foldmethod=indent
enddef

# Map keys usable in the outline buffer
def SetupOutlineBufferMappings()
  :nnoremap <silent> <buffer> q :quit<CR>
  :nnoremap <silent> <buffer> <CR> <scriptcmd>OutlineJumpToSymbol()<CR>
  :nnoremap <silent> <buffer> p <scriptcmd>OutlineJumpToSymbol(true)<CR>
  :nnoremap <silent> <buffer> K <scriptcmd>OutlineShowSymbolDetail(line('.'))<CR>
  :nnoremap <silent> <buffer> Z <scriptcmd>ToggleOutlineZoom()<CR>
enddef

# Setup the highlight groups and text properties in the outline buffer
def SetupOutlineBufferSyntax()
  hlset([
    {name: 'LspOutlineIcon', default: true, linksto: 'Special'},
    {name: 'LspOutlineKind', default: true, linksto: 'Title'},
    {name: 'LspOutlineCount', default: true, linksto: 'Comment'},
    {name: 'LspOutlineFile', default: true, linksto: 'Directory'},
    {name: 'LspOutlineInfo', default: true, linksto: 'Comment'}
  ])

  # highlight the symbol kind icons
  prop_type_add('LspOutlineIcon', {
    bufnr: bufnr(),
    highlight: 'LspOutlineIcon'
  })

  # highlight the symbol kinds (e.g. Function, Variable)
  prop_type_add('LspOutlineKind', {
    bufnr: bufnr(),
    highlight: 'LspOutlineKind'
  })

  # highlight the number of symbols of a kind
  prop_type_add('LspOutlineCount', {
    bufnr: bufnr(),
    highlight: 'LspOutlineCount'
  })

  # highlight the file name in the header
  prop_type_add('LspOutlineFile', {
    bufnr: bufnr(),
    highlight: 'LspOutlineFile'
  })

  # highlight the directory name and informational messages
  prop_type_add('LspOutlineInfo', {
    bufnr: bufnr(),
    highlight: 'LspOutlineInfo'
  })

  prop_type_add('LspOutlineHighlight', {
    bufnr: bufnr(),
    highlight: 'Search',
    override: true
  })
enddef

# Setup outline autocmds
def SetupOutlineAutocmds()
  try
    autocmd_delete([{group: 'LSPOutline', event: '*'}])
  catch /E367:/
  endtry
  var acmds: list<dict<any>>

  # Refresh or add the symbols in a buffer to the outline window
  acmds->add({event: 'BufEnter',
	      group: 'LSPOutline',
	      pattern: '*',
	      replace: true,
	      cmd: 'call g:LspRequestDocSymbols()'})

  # when the outline window is closed, do the cleanup
  acmds->add({event: 'BufUnload',
	      group: 'LSPOutline',
	      pattern: 'LSP-Outline',
	      replace: true,
	      cmd: 'OutlineCleanup()'})

  # Highlight the current symbol when the cursor is not moved for sometime
  acmds->add({event: 'CursorHold',
	      group: 'LSPOutline',
	      pattern: '*',
	      replace: true,
	      cmd: 'OutlineHighlightCurrentSymbol()'})

  autocmd_add(acmds)
enddef

def Open(cmdmods: string, winsize: number)
  var prevWinID: number = win_getid()

  var mods = cmdmods
  if mods->empty()
    if opt.lspOptions.outlineOnRight
      mods = ':vert :botright'
    else
      mods = ':vert :topleft'
    endif
  endif

  var size = winsize
  if size == 0
    size = opt.lspOptions.outlineWinSize
  endif

  silent execute $'{mods} :{size}new LSP-Outline'
  :setlocal modifiable
  :setlocal noreadonly
  deletebufline('', 1, '$')

  SetOutlineBufferOptions()
  SetupOutlineBufferMappings()

  setline(1, ['Loading symbols...'])
  :setlocal nomodifiable

  SetupOutlineBufferSyntax()

  SetupOutlineAutocmds()

  if exists('#User#LspOutlineSetup')
    :doautocmd <nomodeline> User LspOutlineSetup
  endif

  prevWinID->win_gotoid()
enddef

# vim: tabstop=8 shiftwidth=2 softtabstop=2 noexpandtab
