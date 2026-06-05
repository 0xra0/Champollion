<#
  Decompiled_PSC_Repair v3.00

.SYNOPSIS
Decompiled Papyrus (.psc) repair pipeline for Starfield + DLCs.
Cleans and normalizes Champollion output (current Champollion version 1.3.2 last updated on Nexus 2023-08-03 fails to handle various cases correctly) to ensure PSCs compile correctly and function as originally intended. Originally designed to repair Shattered Space DLC PSCs decompiled with Champollion so these could properly load in the Creation Kit (as BGS didn't provide us with the source PSCs); later expanded to cover any decompiled Starfield PSCs (tested against decompiled PEX of all 5000+ base game+DLC PSCs with 100% successful processing and CK compilation).

.DESCRIPTION
Walks your source tree, processes each *.psc, and emits repaired files into sibling **Processed** folders while mirroring the input directory structure.
Transforms are conservative and deterministic (guards, events/sender types, header cleanup, whitespace/line endings, etc.).

KEY FIXES (non-exhaustive)
- Repair fragment structure (adds comments the CK requires, etc.)
- Guard/LockGuard normalization; prune empty/pointless guard blocks
- Resolve guard contract conflicts (align RequiresGuard with callsites)
- Infer/restore Property RequiresGuard when provable
- Repair custom event sender types (e.g., OnCombatStateChanged → Actor)
- Replace overly-generic “as ScriptObject” with concrete types when safe
- Trim Champollion headers; normalize whitespace; CRLF line endings
- Avoid introducing parameter default mismatches with originals

REQUIREMENTS
- Windows PowerShell 5.1 (targeted semantics)
- Champollion-decompiled *.psc inputs
- Optional: Creation Kit / PapyrusCompiler for post-pass compile checks

FOLDER LAYOUT (example)
- Root\
  ├─ Original\              # decompiled sources (input)
  ├─ Processed\             # auto-created; repaired outputs mirror input tree
  └─ Decompiled_PSC_Repair.ps1

WRITE BEHAVIOR (IMPORTANT)
- First run over raw Champollion output: most files will be rewritten (to **Processed** folder or specified output folder).
- Re-running on already-processed files: files are only rewritten if the computed output differs from what’s on disk; otherwise they are skipped.
- Final summary prints Skipped/Processed counts.

QUICK START
0) Decompile desired PEX files using Champollion. If the focus is on Shattered Space DLC scripts, use BAE or similar to extract PEX from "ShatteredSpace - Main01.ba2" in your Starfield Data folder to your new project folder, then use Champollion to mass decompile those PEX files (I generally use:
.\Champollion.exe .\ -r -v -e --no-debug-line
...to recurse all subdirectories in my project folder where Champollion.exe is a directory above the files to be decompiled so it can decompile all files in all directories within the directory Champollion is in, and drop them in the same directory as their corresponding PEX file). You may have to temporarily remove or exclude sfbgs001interactiveobjectsequencer.psc, then later run Champollion only on that PSC with -r removed from the command, as Champollion seems to hang or crash on that PSC when running against a batch, but provides partial output when running on that single PSC.
1) Assuming a directory structure as described above, place Decompiled_PSC_Repair.ps1 in your project's root folder.
2) Open **Windows PowerShell 5.1** and change directory to your project root folder, or right-click in empty space in a window and choose "Open in Terminal".
3) Run Decompiled_PSC_Repair.ps1 (omit "powershell -ExecutionPolicy Bypass -File" if not required by your environment; omit "-Force" if desired):
	powershell -ExecutionPolicy Bypass -File .\Decompiled_PSC_Repair.ps1 -Path ".\Original" ".\Processed" -force
   The script will:
     • Discover *.psc under your configured input root (commonly “Original”)
     • Write repaired files under sibling “Processed” folders
     • Print a summary: “ps1 script – Skipped: N; Processed: M”
	 Note: If you use Tab to autocomplete directory names when entering the above command, remember to remove any backslashes at the ends of your directories in the command, or you will get an error and the script will fail to execute (it's a Windows/PowerShell limitation, not an issue with the script).
4) If desired, copy processed PSCs into Starfield Data\Scripts\Source folders as appropriate.

NOTES & LIMITATIONS
- If Champollion drops type info, fixes default to conservative (no-op) rather than risky edits.
- Champollion sometimes fails to carry over parentheses in math into decompiled output; this script can't guess/fix that.
- Guard inference is evidence-based to avoid false positives, but inherently imperfect as Champollion does not carry RequiresGuard or ProtectsFunctionLogic during decompilation. Thousands of tests successfully process and compile, but there is no guarantee that guard functionality is as originally intended in a given PSC; this is best-effort repair.
- Since Champollion currently crashes or freezes during decompilation of sfbgs001interactiveobjectsequencer.psc from dlc001 (Shattered Space), this script takes any partial decompilation of that PSC and comments the entire script except the ScriptName line. This allows the CK to compile and interpret it as a dummy PSC, but it's essentially for reference only at that point.
- This script skips all "native" and PEO-related PSCs, as Champollion mangles these especially badly and no one should ever need to decompile them anyway (the source PSCs are provided with the game).
#>



param(
  [Parameter(Mandatory=$true)]
  [string]$Path,               # file.psc or folder
  [switch]$Force,              # overwrite outputs in OutRoot
  [switch]$IncludeFixed,       # include inputs under OutRoot
  [string]$OutRoot             # top-level mirror output root (optional)
)


function Normalize-ChampHeader {
    param(
        [Parameter(Mandatory)]
        [byte[]] $Bytes
    )
    # Detect UTF-8 BOM
    $hasBom = ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF)
    $utf8NoBom   = New-Object System.Text.UTF8Encoding($false)
    $utf8WithBom = New-Object System.Text.UTF8Encoding($true)

    # Decode and strip BOM char so ^ matches start of content
    $text = [System.Text.Encoding]::UTF8.GetString($Bytes)
    if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }

    # Collapse *leading* Champollion block ;/ ... /; to one line
    $pattern = '(?s)^\s*;\/.*?\/;\s*'
    if ([System.Text.RegularExpressions.Regex]::IsMatch($text, $pattern)) {
        $normalized = [System.Text.RegularExpressions.Regex]::Replace($text, $pattern, "; Decompiled by Champollion and processed by Decompiled_PSC_Repair by LBGSHI`r`n")
        $enc = if ($hasBom) { $utf8WithBom } else { $utf8NoBom }
        return @{
            Bytes    = $enc.GetBytes($normalized)
            Changed  = $true
            Encoding = $enc
        }
    } else {
        $enc = if ($hasBom) { $utf8WithBom } else { $utf8NoBom }
        return @{
            Bytes    = $Bytes
            Changed  = $false
            Encoding = $enc
        }
    }
}



$ErrorActionPreference = 'Stop'
$NL = "`r`n"


# Determine base input root and the mirror output root.
$__pathItem = Get-Item -LiteralPath $Path
if ($__pathItem.PSIsContainer) {
  $Script:BaseRoot = $__pathItem.FullName
} else {
  $Script:BaseRoot = Split-Path -Parent $__pathItem.FullName
}
# Default OutRoot: a sibling "Processed" folder next to the BaseRoot (single top-level mirror).
# Normalize absolute paths and guard against OutRoot inside input root
$Script:BaseRoot = (Resolve-Path -LiteralPath $Script:BaseRoot).ProviderPath
if (-not $OutRoot -or ([string]$OutRoot).Trim() -eq "") {
  $Script:OutRoot = Join-Path (Split-Path -Parent $Script:BaseRoot) "Processed"
} else {
  # PS 5.1-safe resolve (no null-conditional)
  if (Test-Path -LiteralPath $OutRoot) {
    $tmpOut = (Resolve-Path -LiteralPath $OutRoot).ProviderPath
  } else {
    $tmpOut = $OutRoot  # may not exist yet
  }
  $Script:OutRoot = $tmpOut
}

function _NormPath([string]$p) {
  if ([string]::IsNullOrWhiteSpace($p)) { return $p }
  $n = $p.TrimEnd('\','/')
  return $n + '\'
}
$BaseRootN = _NormPath $Script:BaseRoot
$OutRootN  = _NormPath $Script:OutRoot

if ($OutRootN -like ($BaseRootN + '*')) {
  throw "OutRoot ('$($Script:OutRoot)') must NOT be inside the input root ('$($Script:BaseRoot)'). Specify -OutRoot outside the input tree."
}
# Files to skip entirely (native and PEO base PSCs that Champollion cannot decompile reliably)
$SkipFiles = @(
  "Action.psc","Activator.psc","ActiveMagicEffect.psc","Actor.psc","ActorBase.psc","ActorValue.psc","AffinityEvent.psc","Alias.psc",
  "Ammo.psc","Armor.psc","AssociationType.psc","Book.psc","CameraShot.psc","Cell.psc","Challenge.psc","Class.psc","CombatStyle.psc",
  "ConditionForm.psc","ConstructibleObject.psc","Container.psc","Curve.psc","Debug.psc","Door.psc","EffectShader.psc","Enchantment.psc",
  "Explosion.psc","Faction.psc","Flora.psc","Form.psc","FormList.psc","Furniture.psc","Game.psc","GameplayOption.psc",
  "GlobalVariable.psc","Hazard.psc","HeadPart.psc","Idle.psc","IdleMarker.psc","ImageSpaceModifier.psc","ImpactDataSet.psc",
  "Ingredient.psc","InputEnableLayer.psc","InstanceNamingRules.psc","Key.psc","Keyword.psc","LegendaryItem.psc","LeveledActor.psc",
  "LeveledItem.psc","LeveledSpaceshipBase.psc","LeveledSpell.psc","Light.psc","Location.psc","LocationAlias.psc","LocationRefType.psc",
  "MagicEffect.psc","Math.psc","Message.psc","MiscObject.psc","MovableStatic.psc","MusicType.psc","Note.psc","ObjectMod.psc",
  "ObjectReference.psc","Outfit.psc","Package.psc","PackIn.psc","peo_sleephealingscript.psc","peo_sustenancecastwatchscript.psc","peo_sustenancestart.psc","Perk.psc","Planet.psc","Potion.psc","Projectile.psc","Quest.psc","Race.psc",
  "RefCollectionAlias.psc","ReferenceAlias.psc","ResearchProject.psc","Resource.psc","Scene.psc","ScriptObject.psc","Scroll.psc",
  "ShaderParticleGeometry.psc","Shout.psc","SoulGem.psc","SpaceshipBase.psc","SpaceshipReference.psc","SpeechChallengeObject.psc",
  "Spell.psc","sq_peo_questscript.psc","Static.psc","TalkingActivator.psc","Terminal.psc","TerminalMenu.psc","TextureSet.psc","Topic.psc","TopicInfo.psc",
  "Utility.psc","VisualEffect.psc","VoiceType.psc","Weapon.psc","Weather.psc","WordOfPower.psc","WorldSpace.psc","WwiseEvent.psc"
)


Write-Host ("BaseRoot: {0}" -f $Script:BaseRoot) -ForegroundColor DarkGray
Write-Host ("OutRoot : {0}" -f $Script:OutRoot) -ForegroundColor DarkGray

# --- Stats ---
$Script:StatChanged = 0
$Script:StatCopied  = 0
$Script:StatExists  = 0
$Script:StatFailed  = 0
if (-not $OutRoot -or ([string]$OutRoot).Trim() -eq "") {
  $Script:OutRoot = Join-Path (Split-Path -Parent $Script:BaseRoot) "Processed"
} else {
  $Script:OutRoot = $OutRoot
}

function Get-PscFiles($root) {
  if (-not (Test-Path -LiteralPath $root)) { throw "Path not found: $root" }
  $it = Get-Item -LiteralPath $root
  if ($it.PSIsContainer) {
    $all = Get-ChildItem -LiteralPath $it.FullName -Recurse -Filter *.psc -File
    if (-not $IncludeFixed) { $all = $all | Where-Object { $_.FullName -notlike ($Script:OutRoot + '*') -and $_.DirectoryName -notmatch '(^|[\\/])Processed([\\/]|$)' } }
    return $all
  } else {
    if ($it.Extension -ieq '.psc') { ,$it } else { @() }
  }
}

function Get-FixedOutPath($inFile) {
  # Build path under OutRoot mirroring the directory structure beneath BaseRoot.
  $full = $inFile.FullName
  $rel  = $full.Substring($Script:BaseRoot.Length).TrimStart('\','/')
  $out  = Join-Path $Script:OutRoot $rel
  return $out
}



function Get-CodePortion([string]$line) {
  if ([string]::IsNullOrEmpty($line)) { return "" }
  $i = 0; $inStr = $false
  while ($i -lt $line.Length) {
    $ch = $line[$i]
    if ($ch -eq '"') { $inStr = -not $inStr; $i++; continue }
    if (-not $inStr -and $ch -eq ';') { break }
    $i++
  }
  $code = ([string]$line).Substring(0, $i)
  return ($code -replace '^\s+', '')
}

function Is-FirstToken([string]$code, [string]$tok) {
  return ($code -match ('^(?i)' + [regex]::Escape($tok) + '(\b|$)'))
}

function Remove-ChampollionBanner([string[]]$lines) {
  if ($lines.Count -gt 0) { $lines[0] = $lines[0].TrimStart([char]0xFEFF) }
  if ($lines.Count -gt 0 -and $lines[0] -match '^\s*;/' ) {
    $endIdx = ($lines | Select-String -Pattern '^\s*/;\s*$' -SimpleMatch | Select-Object -First 1).LineNumber
    if ($endIdx) { $lines = $lines[($endIdx)..($lines.Count-1)] }
  }
  return ,$lines
}





function Build-GlobalPropTypes {
  param([string[]]$Lines)
  $map = @{}
  foreach ($line in $Lines) {
    $m = [regex]::Match($line, '^\s*([A-Za-z0-9_:]+)\s+Property\s+([A-Za-z_][A-Za-z0-9_]*)\b')
    if ($m.Success) { $map[$m.Groups[2].Value] = $m.Groups[1].Value }
  }
  return $map
}

function Get-LocalTypeMap {
  param(
    [string[]]$Lines,
    [int]$EventStartIndex,
    [int]$EventEndIndex,
    [hashtable]$GlobalPropsTypeMap
  )
  $map = @{}

  # Local declarations and casts
  $rxDecl = '^\s*([A-Za-z0-9_:]+)\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?:=|$)'
  $rxAs   = '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*.+\s+as\s+([A-Za-z0-9_:]+)\s*$'
  $rxGAR  = '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*.*\bGetActorRef(?:erence)?\s*\('
  $rxGR   = '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*.*\bGetReference\s*\('

  # Array index expression pattern (e.g., sources[I])
  $rxIndexExpr = '([A-Za-z_][A-Za-z0-9_]*\[[^\]]+\])'
  # Learn "RHS as Type" on index expressions (e.g., Actor x = sources[I] as Actor)
  $rxIndexRhsAs = '^\s*[A-Za-z0-9_:]+\s+[A-Za-z_][A-Za-z0-9_]*\s*=\s*' + $rxIndexExpr + '\s+as\s+([A-Za-z0-9_:]+)\s*$'

  # Dotted LHS variants (e.g., current.modulatorRef = expr as Type)
  $rxAsDot  = '^\s*([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)+)\s*=\s*.+\s+as\s+([A-Za-z0-9_:]+)\s*$'
  $rxGARDot = '^\s*([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)+)\s*=\s*.*\bGetActorRef(?:erence)?\s*\('
  $rxGRDot  = '^\s*([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)+)\s*=\s*.*\bGetReference\s*\('

  # Learn parameter types from the Event/Function signature line
  $sigLine = $Lines[$EventStartIndex]
  $mSig = [regex]::Match($sigLine, '^\s*(Event|Function)\s+[A-Za-z0-9_:]+\s*\((.*?)\)')
  if ($mSig.Success) {
    $paramList = $mSig.Groups[2].Value
    foreach ($p in ($paramList -split '\s*,\s*')) {
      if ([string]::IsNullOrWhiteSpace($p)) { continue }
      $mP = [regex]::Match($p, '^\s*([A-Za-z0-9_:]+)\s+([A-Za-z_][A-Za-z0-9_]*)\s*$')
      if ($mP.Success) { $map[$mP.Groups[2].Value] = $mP.Groups[1].Value }
    }
  }

  for ($i = $EventStartIndex; $i -le $EventEndIndex; $i++) {
    $line = $Lines[$i]
    $m = [regex]::Match($line, $rxDecl);   if ($m.Success) { $map[$m.Groups[2].Value] = $m.Groups[1].Value; continue }
    $m = [regex]::Match($line, $rxAs);     if ($m.Success) { $map[$m.Groups[1].Value] = $m.Groups[2].Value; continue }
    $m = [regex]::Match($line, $rxGAR);    if ($m.Success) { $map[$m.Groups[1].Value] = 'Actor'; continue }
    $m = [regex]::Match($line, $rxGR);     if ($m.Success) { $map[$m.Groups[1].Value] = 'ObjectReference'; continue }
    # RHS index cast: map sources[I] → Type
    $m = [regex]::Match($line, $rxIndexRhsAs); if ($m.Success) { $map[$m.Groups[1].Value] = $m.Groups[2].Value; continue }


    # Dotted LHS
    $m = [regex]::Match($line, $rxAsDot);  if ($m.Success) { $map[$m.Groups[1].Value] = $m.Groups[2].Value; continue }
    $m = [regex]::Match($line, $rxGARDot); if ($m.Success) { $map[$m.Groups[1].Value] = 'Actor'; continue }
    $m = [regex]::Match($line, $rxGRDot);  if ($m.Success) { $map[$m.Groups[1].Value] = 'ObjectReference'; continue }
  }

  foreach ($k in $GlobalPropsTypeMap.Keys) {
    if (-not $map.ContainsKey($k)) { $map[$k] = $GlobalPropsTypeMap[$k] }
  }
  return $map
}


function Infer-Type-From-Expr {
  param(
    [string]$Expr,
    [hashtable]$LocalTypeMap
  )
  if ([string]::IsNullOrWhiteSpace($Expr)) { return $null }

  # API clues
  if ($Expr -match '\bGetActorRef(?:erence)?\s*\(') { return 'Actor' }
  if ($Expr -match '\bGetReference\s*\(')            { return 'ObjectReference' }
  if ($Expr -match '\bGetRef\s*\(')                 { return 'ObjectReference' }

  # Explicit cast
  $m = [regex]::Match($Expr, '\bas\s+([A-Za-z0-9_:]+)\b')
  if ($m.Success) {
    $t = $m.Groups[1].Value
    if ($t -ne 'ScriptObject') { return $t }
    # If 'as ScriptObject', try dotted path first, then simple identifier
    $mDot = [regex]::Match($Expr, '^\s*([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)+)\b')
    if ($mDot.Success -and $LocalTypeMap.ContainsKey($mDot.Groups[1].Value)) { return $LocalTypeMap[$mDot.Groups[1].Value] }
    $mId = [regex]::Match($Expr, '^(?:Self\.)?([A-Za-z_][A-Za-z0-9_]*)\b')
    if ($mId.Success -and $LocalTypeMap.ContainsKey($mId.Groups[1].Value)) { return $LocalTypeMap[$mId.Groups[1].Value] }
  }

  # Dotted path first
    # Bracketed index expression: e.g., sources[I]
  $mIdx = [regex]::Match($Expr, '^\s*([A-Za-z_][A-Za-z0-9_]*\[[^\]]+\])')
  if ($mIdx.Success -and $LocalTypeMap.ContainsKey($mIdx.Groups[1].Value)) { return $LocalTypeMap[$mIdx.Groups[1].Value] }
$mDot2 = [regex]::Match($Expr, '^\s*([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)+)\b')
  if ($mDot2.Success -and $LocalTypeMap.ContainsKey($mDot2.Groups[1].Value)) { return $LocalTypeMap[$mDot2.Groups[1].Value] }

  # Simple identifier
  $m = [regex]::Match($Expr, '^(?:Self\.)?([A-Za-z_][A-Za-z0-9_]*)\b')
  if ($m.Success) {
    $id = $m.Groups[1].Value
    if ($LocalTypeMap.ContainsKey($id)) { return $LocalTypeMap[$id] }
  }

  return $null
}


function PreInfer-EventSenderTypes {
  param([string]$Text)
  if ($null -eq $Text) { return $Text }

  $lines = $Text -replace "`r`n?", "`n"
  $lines = $lines -split "`n", 0, 'SimpleMatch'

  # Learn typed handlers (these win)
  $handlerTypeByEvent = @{}
  foreach ($line in $lines) {
    $mh = [regex]::Match($line, '^\s*Event\s+([A-Za-z0-9_:]+)\s*(?:[._])\s*(On[A-Za-z0-9_]+)\s*\(')
    if ($mh.Success) { $handlerTypeByEvent[$mh.Groups[2].Value] = $mh.Groups[1].Value }
  }

  $globalPropTypes = Build-GlobalPropTypes -Lines $lines
  $rxCall = '^(?<indent>\s*)(?:Self\.)?(?<fn>RegisterFor(?:Remote|Custom)Event|UnregisterFor(?:Remote|Custom)Event)\(\s*(?<expr>[^,]+?)\s*,\s*"(?<ev>[^"]+)"\s*\)(?<tail>.*)$'

  for ($i = 0; $i -lt $lines.Length; $i++) {
    $m = [regex]::Match($lines[$i], $rxCall)
    if (-not $m.Success) { continue }

    $eventName = $m.Groups['ev'].Value
    $expr      = $m.Groups['expr'].Value

    $resolved = $null
    if ($handlerTypeByEvent.ContainsKey($eventName)) {
      $resolved = $handlerTypeByEvent[$eventName]
    }

    if (-not $resolved) {
      $evStart = $i
    $blockType = $null
      while ($evStart -ge 0) { $line = $lines[$evStart]; if ($line -match '^\s*Event\b') { $blockType = 'Event'; break } if ($line -match '^\s*Function\b') { $blockType = 'Function'; break } $evStart-- }
      $evEnd = $i
      if ($blockType -eq 'Event') { while ($evEnd -lt $lines.Length -and ($lines[$evEnd] -notmatch '^\s*EndEvent\b')) { $evEnd++ } } else { while ($evEnd -lt $lines.Length -and ($lines[$evEnd] -notmatch '^\s*EndFunction\b')) { $evEnd++ } }

      if ($evStart -ge 0 -and $evEnd -lt $lines.Length) {
        $localMap = Get-LocalTypeMap -Lines $lines -EventStartIndex $evStart -EventEndIndex $evEnd -GlobalPropsTypeMap $globalPropTypes
        $resolved = Infer-Type-From-Expr -Expr $expr -LocalTypeMap $localMap
    # Avoid casting to alias types here; let later logic decide how to transform aliases
    if ($resolved -and $resolved -in @('ReferenceAlias','RefCollectionAlias','LocationAlias')) { $resolved = $null }

      }
    }

    if (-not $resolved) { continue }

    # Modify expression based on inference
    $mCast = [regex]::Match($expr, '\bas\s+([A-Za-z0-9_:]+)\b')
    if ($mCast.Success -and $mCast.Groups[1].Value -ne 'ScriptObject') {
      # Explicit non-ScriptObject cast present
      $explicit = $mCast.Groups[1].Value
      # Upgrade ObjectReference -> Actor when local inference says Actor
      if ($resolved -and $explicit -eq 'ObjectReference' -and $resolved -eq 'Actor') {
        $newExpr = [regex]::Replace($expr, '\bas\s+ObjectReference\b', 'as Actor')
      } else {
        continue
      }
    } else {
      # No cast or ScriptObject cast → apply inferred type
      $newExpr = if ($expr -match '\bas\s+ScriptObject\b') {
        [regex]::Replace($expr, '\bas\s+ScriptObject\b', ('as ' + $resolved))
      } else {
        ($expr.TrimEnd() + ' as ' + $resolved)
      }
    }
$lines[$i] = ($m.Groups['indent'].Value + $m.Groups['fn'].Value + '(' + $newExpr + ', "' + $eventName + '")' + $m.Groups['tail'].Value)
  }

  $joined = ($lines -join "`n") -replace "`n", "$NL"
  return ($joined.TrimEnd() + $NL)
}
function Fix-EventRegistrations([string]$text) {
  if ($null -eq $text) { return $text }
  $lf = ($text -replace "`r`n?", "`n")
  $lines = $lf -split "`n", 0, 'SimpleMatch'

  # Fallback sender types for common remote events (used if no typed handler is found in this script)
  $fallback = @{
}
# Global pre-pass: sanitize any colon-prefixed custom event literals and normalize SendCustomEvent calls
  for ($i=0; $i -lt $lines.Count; $i++) {
    $ln = $lines[$i]
    if ($ln -match 'RegisterForCustomEvent\([^,]+,\s*"([^"]+:[^"]+)"\)') {
      $ln = [regex]::Replace($ln, '(RegisterForCustomEvent\([^,]+,\s*")([^"]+:[^"]+)(")', { param($m) $m.Groups[1].Value + (Sanitize-EventName $m.Groups[2].Value) + $m.Groups[3].Value })
    }
    if ($ln -match 'UnregisterForCustomEvent\([^,]+,\s*"([^"]+:[^"]+)"\)') {
      $ln = [regex]::Replace($ln, '(UnregisterForCustomEvent\([^,]+,\s*")([^"]+:[^"]+)(")', { param($m) $m.Groups[1].Value + (Sanitize-EventName $m.Groups[2].Value) + $m.Groups[3].Value })
    }
    # Normalize any X.SendCustomEvent("...") or Self.SendCustomEvent("...")
    if ($ln -match '\b([A-Za-z0-9_\.]+)?SendCustomEvent\(\s*"([^"]+)"') {
      $ln = [regex]::Replace($ln, '(\b[A-Za-z0-9_\.]*SendCustomEvent\(\s*")([^"]+)(")', { param($m) $m.Groups[1].Value + (Sanitize-EventName $m.Groups[2].Value) + $m.Groups[3].Value })
    }
    $lines[$i] = $ln
  }

  # Learn event sender types from handler declarations: Event <Type>.<Name>(<Type> <anyName>, ...)
  $map = @{}  # name -> type
  $evRx = [regex]'^\s*Event\s+([A-Za-z0-9_:]+)\.([A-Za-z0-9_]+)\s*\(\s*([A-Za-z0-9_:]+)\s+[A-Za-z0-9_]+\b'
  $rxUS = [regex]'^\s*Event\s+([A-Za-z0-9_]+)_([A-Za-z0-9_]+)\s*\(\s*([A-Za-z0-9_:]+)\s+[A-Za-z0-9_]+'
  foreach ($ln in $lines) {
    $m = $evRx.Match($ln)
    if ($m.Success) {
      $senderType = $m.Groups[3].Value
      $eventName  = $m.Groups[2].Value
      $map[$eventName] = $senderType
    }
  foreach ($ln in $lines) {
    $m2 = $rxUS.Match($ln)
    if ($m2.Success) {
      $senderType = $m2.Groups[3].Value
      $eventName  = $m2.Groups[2].Value
      if (-not $map.ContainsKey($eventName)) { $map[$eventName] = $senderType }
    }
  }
  }

  # If no handlers are present in this script, seed the map from fallback for any
# remote events that appear in Register/Unregister lines. This lets us fix casts
# like ScriptObject -> Actor for known events (e.g., OnCombatStateChanged).
if ($map.Count -eq 0) {
  foreach ($name in $fallback.Keys) {
    $q = [regex]::Escape($name)
    $found = $false
    foreach ($ln in $lines) {
      if ($ln -match 'RegisterForRemoteEvent\(' -and $ln -match ('"' + $q + '"')) { $found = $true; break }
      if ($ln -match 'UnregisterForRemoteEvent\(' -and $ln -match ('"' + $q + '"')) { $found = $true; break }
    }
    if ($found) { $map[$name] = $fallback[$name] }
  }
  if ($map.Count -eq 0) { return $text } # still nothing to do
}


  function Normalize-TypeToPrefix([string]$t) {
    if ([string]::IsNullOrEmpty($t)) { return $t }
    $t2 = $t
    $idx = $t2.LastIndexOf(':')
    if ($idx -ge 0 -and $idx + 1 -lt $t2.Length) { $t2 = $t2.Substring($idx + 1) }
    return $t2.ToLower()
  }

  for ($i=0; $i -lt $lines.Count; $i++) {
    $ln = $lines[$i]

    foreach ($kv in $map.GetEnumerator()) {
      # Sanitize any colon-prefixed custom event string arguments, independent of mapping
      if ($ln -match 'RegisterForCustomEvent\([^,]+,\s*"([^"]+:[^"]+)"\)') {
        $ln = [regex]::Replace($ln, '(RegisterForCustomEvent\([^,]+,\s*")([^"]+:[^"]+)(")', { param($m) $m.Groups[1].Value + (Sanitize-EventName $m.Groups[2].Value) + $m.Groups[3].Value })
      }
      if ($ln -match 'UnregisterForCustomEvent\([^,]+,\s*"([^"]+:[^"]+)"\)') {
        $ln = [regex]::Replace($ln, '(UnregisterForCustomEvent\([^,]+,\s*")([^"]+:[^"]+)(")', { param($m) $m.Groups[1].Value + (Sanitize-EventName $m.Groups[2].Value) + $m.Groups[3].Value })
      }

      $name = $kv.Key
      $typ = $kv.Value; if (-not $typ) { if ($fallback.ContainsKey($name)) { $typ = $fallback[$name] } }
      $prefix = (Normalize-TypeToPrefix $typ)

      # --- Remote events ---
      if ($ln -match ('RegisterForRemoteEvent\(') -and $ln -match ('"'+[regex]::Escape($name)+'"')) {
        $re = [regex]('^(.*RegisterForRemoteEvent\([^,]+?\s+as\s+)(ScriptObject)(\s*,\s*"' + [regex]::Escape($name) + '"\).*)$')
        if ($re.IsMatch($ln)) {
          $ln = $re.Replace($ln, ('$1' + $typ + '$3'))
        } else {
          $re2 = [regex]('^(.*RegisterForRemoteEvent\((?![^,]*\bas\s+[A-Za-z0-9_:]+\b)([^,]+))(\s*,\s*"' + [regex]::Escape($name) + '"\).*)$')
          if ($re2.IsMatch($ln)) { $ln = $re2.Replace($ln, ('$1 as ' + $typ + '$2')) }
        }
      }
      if ($ln -match ('UnregisterForRemoteEvent\(') -and $ln -match ('"'+[regex]::Escape($name)+'"')) {
        $re = [regex]('^(.*UnregisterForRemoteEvent\([^,]+?\s+as\s+)(ScriptObject)(\s*,\s*"' + [regex]::Escape($name) + '"\).*)$')
        if ($re.IsMatch($ln)) {
          $ln = $re.Replace($ln, ('$1' + $typ + '$3'))
        } else {
          $re2 = [regex]('^(.*UnregisterForRemoteEvent\((?![^,]*\bas\s+[A-Za-z0-9_:]+\b)([^,]+))(\s*,\s*"' + [regex]::Escape($name) + '"\).*)$')
          if ($re2.IsMatch($ln)) { $ln = $re2.Replace($ln, ('$1 as ' + $typ + '$2')) }
        }
      }

      # --- Custom events: cast fix + optional name normalization ---
      if ($ln -match ('RegisterForCustomEvent\(') -and $ln -match ('"' + [regex]::Escape($name) + '"|"' + [regex]::Escape($prefix) + '_' + [regex]::Escape($name) + '"')) {
        # Fix cast
        $reC = [regex]('^(.*RegisterForCustomEvent\([^,]+?\s+as\s+)(ScriptObject)(\s*,\s*"(?:' + [regex]::Escape($prefix) + '_)?' + [regex]::Escape($name) + '"\).*)$')
        if ($reC.IsMatch($ln)) {
          $ln = $reC.Replace($ln, ('$1' + $typ + '$3'))
        } else {
          $reC2 = [regex]('^(.*RegisterForCustomEvent\((?![^,]*\bas\s+[A-Za-z0-9_:]+\b)([^,]+))(\s*,\s*"(?:' + [regex]::Escape($prefix) + '_)?' + [regex]::Escape($name) + '"\).*)$')
          if ($reC2.IsMatch($ln)) { $ln = $reC2.Replace($ln, ('$1 as ' + $typ + '$2')) }
        }
        # Normalize event name for external base scripts (when the string uses "<typeprefix>_<name>")
        $reName = [regex]('^(\s*.*RegisterForCustomEvent\([^,]+?,\s*")' + [regex]::Escape($prefix) + '_' + [regex]::Escape($name) + '("\).*)$')
        if ($reName.IsMatch($ln)) {
          # Leave as-is if current script is the same type (we can add a CustomEvent there)
          # Otherwise, prefer plain event name to match most base-game declarations
          $ln = $reName.Replace($ln, ('$1' + $name + '$2'))
        }
      }

      if ($ln -match ('UnregisterForCustomEvent\(') -and $ln -match ('"' + [regex]::Escape($name) + '"|"' + [regex]::Escape($prefix) + '_' + [regex]::Escape($name) + '"')) {
        $reC = [regex]('^(.*UnregisterForCustomEvent\([^,]+?\s+as\s+)(ScriptObject)(\s*,\s*"(?:' + [regex]::Escape($prefix) + '_)?' + [regex]::Escape($name) + '"\).*)$')
        if ($reC.IsMatch($ln)) {
          $ln = $reC.Replace($ln, ('$1' + $typ + '$3'))
        } else {
          $reC2 = [regex]('^(.*UnregisterForCustomEvent\((?![^,]*\bas\s+[A-Za-z0-9_:]+\b)([^,]+))(\s*,\s*"(?:' + [regex]::Escape($prefix) + '_)?' + [regex]::Escape($name) + '"\).*)$')
          if ($reC2.IsMatch($ln)) { $ln = $reC2.Replace($ln, ('$1 as ' + $typ + '$2')) }
        }
        $reName = [regex]('^(\s*.*UnregisterForCustomEvent\([^,]+?,\s*")' + [regex]::Escape($prefix) + '_' + [regex]::Escape($name) + '("\).*)$')
        if ($reName.IsMatch($ln)) {
          $ln = $reName.Replace($ln, ('$1' + $name + '$2'))
        }
      }
    }
    # If no mapped typed handler existed, still try to fix casts using fallback table
    if ($ln -match 'RegisterForRemoteEvent\(') {
      $mname = [regex]::Match($ln, '"([A-Za-z0-9_]+)"')
      if ($mname.Success -and $fallback.ContainsKey($mname.Groups[1].Value)) {
        $typ2 = $fallback[$mname.Groups[1].Value]
        $reF = [regex]('^(.*RegisterForRemoteEvent\([^,]+?\s+as\s+)(ScriptObject)(\s*,\s*"' + [regex]::Escape($mname.Groups[1].Value) + '"\).*)$')
        if ($reF.IsMatch($ln)) {
          $ln = $reF.Replace($ln, ('$1' + $typ2 + '$3'))
        } else {
          $reF2 = [regex]('^(.*RegisterForRemoteEvent\((?![^,]*\bas\s+[A-Za-z0-9_:]+\b)([^,]+))(\s*,\s*"' + [regex]::Escape($mname.Groups[1].Value) + '"\).*)$')
          if ($reF2.IsMatch($ln)) { $ln = $reF2.Replace($ln, ('$1 as ' + $typ2 + '$2')) }
        }
      }
    }
    if ($ln -match 'UnregisterForRemoteEvent\(') {
      $mname = [regex]::Match($ln, '"([A-Za-z0-9_]+)"')
      if ($mname.Success -and $fallback.ContainsKey($mname.Groups[1].Value)) {
        $typ2 = $fallback[$mname.Groups[1].Value]
        $reF = [regex]('^(.*UnregisterForRemoteEvent\([^,]+?\s+as\s+)(ScriptObject)(\s*,\s*"' + [regex]::Escape($mname.Groups[1].Value) + '"\).*)$')
        if ($reF.IsMatch($ln)) {
          $ln = $reF.Replace($ln, ('$1' + $typ2 + '$3'))
        } else {
          $reF2 = [regex]('^(.*UnregisterForRemoteEvent\((?![^,]*\bas\s+[A-Za-z0-9_:]+\b)([^,]+))(\s*,\s*"' + [regex]::Escape($mname.Groups[1].Value) + '"\).*)$')
          if ($reF2.IsMatch($ln)) { $ln = $reF2.Replace($ln, ('$1 as ' + $typ2 + '$2')) }
        }
      }
    }

    $lines[$i] = $ln
  }

  
  # Post-clean: sanitize any accidental "as <keyword>" in event (un)register calls
  $kwRx = [regex]'(?ix)\bas\s+(If|Else|EndIf|While|EndWhile|Event|Function|State|EndState)\b(?=\s*,\s*")'
  for ($j=0; $j -lt $lines.Count; $j++) {
    $raw = $lines[$j]
    if ($raw -match '\b(RegisterForCustomEvent|UnregisterForCustomEvent|RegisterForRemoteEvent|UnregisterForRemoteEvent)\s*\(') {
      if ($kwRx.IsMatch($raw)) {
        $raw = $kwRx.Replace($raw, 'as ScriptObject')
        $lines[$j] = $raw
      }
    }
  }

  $joined = ($lines -join "`n") -replace "`n", "$NL"
  return ($joined.TrimEnd() + $NL)
}

# Fix-RemoteEventCasts:
# Normalizes RegisterForRemoteEvent calls where the sender is a ReferenceAlias or Game.GetPlayer().
# - Ensures ReferenceAlias.OnLocationChange uses the alias directly (no invalid cast).
# - Ensures Actor.OnLocationChange uses Actor-typed senders (Game.GetPlayer(), alias.GetActorReference()).
# - Leaves other senders unchanged.
function Fix-RemoteEventCasts([string]$text) {
  if ($null -eq $text) { return $text }

  # Work in LF, restore CRLF on return
  $lf = $text -replace "`r`n?", "`n"

  # Collect ReferenceAlias properties
  $aliases = @()
  foreach ($m in [regex]::Matches($lf, '(?m)^\s*ReferenceAlias\s+Property\s+([A-Za-z_][A-Za-z0-9_]*)\b')) {
    $aliases += $m.Groups[1].Value
  }
  $aliasPattern = $null
  if ($aliases.Count -gt 0) {
    $aliasPattern = '(?:' + ([regex]::Escape(($aliases -join '|')).Replace('\|','|')) + ')'
  }

  # Detect handlers declared in this file
  $hasRef_OnLoc   = [regex]::IsMatch($lf, '(?m)^\s*Event\s+ReferenceAlias\.OnLocationChange\s*\(')
  $hasRef_OnAct   = [regex]::IsMatch($lf, '(?m)^\s*Event\s+ReferenceAlias\.OnActivate\s*\(')
  $hasRef_OnTrig  = [regex]::IsMatch($lf, '(?m)^\s*Event\s+ReferenceAlias\.OnTriggerEnter\s*\(')
  $hasRef_OnAdd   = [regex]::IsMatch($lf, '(?m)^\s*Event\s+ReferenceAlias\.OnItemAdded\s*\(')
  $hasRef_OnRem   = [regex]::IsMatch($lf, '(?m)^\s*Event\s+ReferenceAlias\.OnItemRemoved\s*\(')
  $hasActor_OnLoc = [regex]::IsMatch($lf, '(?m)^\s*Event\s+Actor\.OnLocationChange\s*\(')
  $hasAnyActorEvt = $hasActor_OnLoc -or [regex]::IsMatch($lf, '(?m)^\s*Event\s+Actor\.[A-Za-z_][A-Za-z0-9_]*\s*\(')

  if ($aliasPattern) {
    # --- Force ReferenceAlias usage for these events if a ReferenceAlias handler exists in this file ---
    if ($hasRef_OnLoc) {
      $lf = [regex]::Replace($lf,
        '(?:Self\.)?RegisterForRemoteEvent\(\s*(' + $aliasPattern + ')\s*(?:as\s+[A-Za-z0-9_:]+)?\s*,\s*"OnLocationChange"\s*\)',
        'RegisterForRemoteEvent($1, "OnLocationChange")')
    }
    if ($hasRef_OnAct) {
      $lf = [regex]::Replace($lf,
        '(?:Self\.)?RegisterForRemoteEvent\(\s*(' + $aliasPattern + ')\s*(?:as\s+[A-Za-z0-9_:]+)?\s*,\s*"OnActivate"\s*\)',
        'RegisterForRemoteEvent($1, "OnActivate")')
    }
    if ($hasRef_OnTrig) {
      $lf = [regex]::Replace($lf,
        '(?:Self\.)?RegisterForRemoteEvent\(\s*(' + $aliasPattern + ')\s*(?:as\s+[A-Za-z0-9_:]+)?\s*,\s*"OnTriggerEnter"\s*\)',
        'RegisterForRemoteEvent($1, "OnTriggerEnter")')
    }
    if ($hasRef_OnAdd) {
      $lf = [regex]::Replace($lf,
        '(?:Self\.)?RegisterForRemoteEvent\(\s*(' + $aliasPattern + ')\s*(?:as\s+[A-Za-z0-9_:]+)?\s*,\s*"OnItemAdded"\s*\)',
        'RegisterForRemoteEvent($1, "OnItemAdded")')
    }
    if ($hasRef_OnRem) {
      $lf = [regex]::Replace($lf,
        '(?:Self\.)?RegisterForRemoteEvent\(\s*(' + $aliasPattern + ')\s*(?:as\s+[A-Za-z0-9_:]+)?\s*,\s*"OnItemRemoved"\s*\)',
        'RegisterForRemoteEvent($1, "OnItemRemoved")')
    }
  
    # ReferenceAlias with ObjectReference event senders → use GetReference()
  if ($aliasPattern) {
    # Explicit ObjectReference cast
    $lf = [regex]::Replace(
      $lf,
      '(?:Self\.)?RegisterFor(?:Remote|Custom)Event\(\s*(' + $aliasPattern + ')\s+as\s+ObjectReference\s*,',
      'RegisterForRemoteEvent($1.GetReference() as ObjectReference,'
    )
    $lf = [regex]::Replace(
      $lf,
      '(?:Self\.)?UnregisterFor(?:Remote|Custom)Event\(\s*(' + $aliasPattern + ')\s+as\s+ObjectReference\s*,',
      'UnregisterForRemoteEvent($1.GetReference() as ObjectReference,'
    )
  }
  }
# Actor.OnLocationChange: keep Game.GetPlayer() as Actor (remove "as ScriptObject")
  if ($hasActor_OnLoc) {
    $lf = [regex]::Replace(
      $lf,
      '(?:Self\.)?RegisterForRemoteEvent\(\s*Game\.GetPlayer\(\)\s*(?:as\s+ScriptObject)\s*,\s*"OnLocationChange"\s*\)',
      'RegisterForRemoteEvent(Game.GetPlayer(), "OnLocationChange")'
    )
    # Normalize other casts on Game.GetPlayer() to Actor for this event
    $lf = [regex]::Replace(
      $lf,
      '(?:Self\.)?RegisterForRemoteEvent\(\s*Game\.GetPlayer\(\)\s*as\s+[A-Za-z0-9_:]+\s*,\s*"OnLocationChange"\s*\)',
      'RegisterForRemoteEvent(Game.GetPlayer() as Actor, "OnLocationChange")'
    )
  }

  # Generic Actor.* handlers: alias must be converted to the underlying Actor
  if ($hasAnyActorEvt -and $aliasPattern) {
    # Explicit "as Actor"
    $lf = [regex]::Replace(
      $lf,
      '(?:Self\.)?RegisterForRemoteEvent\(\s*(' + $aliasPattern + ')\s+as\s+Actor\s*,',
      'RegisterForRemoteEvent($1.GetActorReference() as Actor,'
    )
    # No cast present
    $lf = [regex]::Replace(
      $lf,
      '(?:Self\.)?RegisterForRemoteEvent\(\s*(' + $aliasPattern + ')\s*,',
      'RegisterForRemoteEvent($1.GetActorReference(),'
    )
  }

  return ($lf -replace "`n","`r`n")
}

function Ensure-CustomEventDecls([string]$text) {
  if ($null -eq $text) { return $text }
  $lf = ($text -replace "`r`n?", "`n")
  $lines = $lf -split "`n", 0, 'SimpleMatch'

  # Collect custom event names referenced in Self.SendCustomEvent("Name", ...)
  $names = New-Object System.Collections.Generic.HashSet[string]
  $sendRx = [regex]'\bSelf\.SendCustomEvent\(\s*"([^"]+)"'
  $regRx  = [regex]'\bRegisterForCustomEvent\([^,]+,\s*\"([^\"]+)\"'
  $unregRx= [regex]'\bUnregisterForCustomEvent\([^,]+,\s*\"([^\"]+)\"'

  foreach ($ln in $lines) {
    $m = $sendRx.Match($ln)
    if ($m.Success) { [void]$names.Add( (Sanitize-EventName $m.Groups[1].Value) ) }

    $m = $regRx.Match($ln)
    if ($m.Success) { [void]$names.Add( (Sanitize-EventName $m.Groups[1].Value) ) }

    $m = $unregRx.Match($ln)
    if ($m.Success) { [void]$names.Add( (Sanitize-EventName $m.Groups[1].Value) ) }
  }

  if ($names.Count -eq 0) { return $text }

  
  # Sanitize names (drop any namespace prefixes)
  $sanitized = New-Object 'System.Collections.Generic.List[string]'
  foreach ($n in $names) { $sanitized.Add( (Sanitize-EventName $n) ) }
  $names = $sanitized
  
# Also drop this script's type prefix (e.g., "sfbgs001masterquestscript_") so we declare bare event names
$scriptType = ''
foreach ($ln in $lines) {
  $m = [regex]::Match($ln, '^\s*ScriptName\s+([A-Za-z0-9_:]+)\b')
  if ($m.Success) { $scriptType = $m.Groups[1].Value; break }
}

# Inline prefix normalization (avoid calling Normalize-TypeToPrefix here)
$selfPrefix = ''
if ($scriptType) {
  $t2 = $scriptType
  $idx = $t2.LastIndexOf(':')
  if ($idx -ge 0 -and $idx + 1 -lt $t2.Length) { $t2 = $t2.Substring($idx + 1) }
  $selfPrefix = $t2.ToLower()
}

if ($selfPrefix) {
  $namesNoPrefix = New-Object 'System.Collections.Generic.HashSet[string]'
  foreach ($n in $names) {
    $n2 = $n
    if ($n2 -and $n2 -match ('^' + [regex]::Escape($selfPrefix) + '_')) {
      $n2 = $n2.Substring($selfPrefix.Length + 1)
    }
    [void]$namesNoPrefix.Add($n2)
  }
  $names = $namesNoPrefix
}


  
# Find insertion point (before first Function/Event line)
  $insertIndex = 0
  for ($i=0; $i -lt $lines.Count; $i++) {
    $trim = $lines[$i].TrimStart()
    if ($trim.StartsWith("Function ") -or $trim.StartsWith("Event ")) { $insertIndex = $i; break }
  }

  # Do not duplicate existing declarations
  $existing = New-Object System.Collections.Generic.HashSet[string]
  $declRx = [regex]'^\s*CustomEvent\s+([A-Za-z0-9_:]+)\s*$'
  foreach ($ln in $lines) {
    $m = $declRx.Match($ln)
    if ($m.Success) { [void]$existing.Add($m.Groups[1].Value) }
  }

  $decls = @()
  foreach ($n in $names) {
    if (-not $existing.Contains($n)) { $decls += ("CustomEvent " + $n) }
  }
  if ($decls.Count -eq 0) { return $text }

  $before = $lines[0..($insertIndex-1)]
  $after  = $lines[$insertIndex..($lines.Count-1)]
  $newLines = @()
  $newLines += $before
  if ($before.Count -gt 0 -and ([string]$before[-1]).Trim() -ne "") { $newLines += "" }
  $newLines += $decls
  if ($after.Count -gt 0 -and ([string]$after[0]).Trim() -ne "") { $newLines += "" }
  $newLines += $after

  
# Normalize Self.SendCustomEvent calls to *bare* event names on the content we will write ($newLines)
for ($i=0; $i -lt $newLines.Count; $i++) {
  $ln = $newLines[$i]

  # 1) Drop any namespace (e.g., "dlc001:") from the literal
  $ln = [regex]::Replace(
    $ln,
    '(\bSelf\.SendCustomEvent\(\s*")([^"]+)(")',
    { param($m) $m.Groups[1].Value + (Sanitize-EventName $m.Groups[2].Value) + $m.Groups[3].Value }
  )

  # 2) If the literal begins with "<selfPrefix>_", strip it to get the bare name
  if ($selfPrefix) {
    $ln = [regex]::Replace(
      $ln,
      '(\bSelf\.SendCustomEvent\(\s*")' + [regex]::Escape($selfPrefix) + '_([A-Za-z0-9_]+)(")',
      { param($m) $m.Groups[1].Value + $m.Groups[2].Value + $m.Groups[3].Value }
    )
  }

  $newLines[$i] = $ln
}

  # Also normalize Register/Unregister string literals to bare names
  for ($i=0; $i -lt $newLines.Count; $i++) {
    $newLines[$i] = [regex]::Replace($newLines[$i], '(\bRegisterForCustomEvent\([^,]+,\s*")([^"]+)(")', { param($m) $m.Groups[1].Value + (Sanitize-EventName $m.Groups[2].Value) + $m.Groups[3].Value })
    $newLines[$i] = [regex]::Replace($newLines[$i], '(\bUnregisterForCustomEvent\([^,]+,\s*")([^"]+)(")', { param($m) $m.Groups[1].Value + (Sanitize-EventName $m.Groups[2].Value) + $m.Groups[3].Value })
  }
# --- Filter out declarations that look external (owner/registration not Self), unless we also send them ---
try {
  $sent = New-Object 'System.Collections.Generic.HashSet[string]'
  $sendRx1 = [regex]'\bSelf\.SendCustomEvent\(\s*"([^"]+)"'
  $sendRx2 = [regex]'\b(?<!\.)SendCustomEvent\(\s*"([^"]+)"'
  foreach ($ln in $lines) {
    $m1 = $sendRx1.Match($ln); if ($m1.Success) { [void]$sent.Add($m1.Groups[1].Value) }
    $m2 = $sendRx2.Match($ln); if ($m2.Success) { [void]$sent.Add($m2.Groups[1].Value) }
  }

  $scriptName = $null
  $snRx = [regex]'^\s*ScriptName\s+([A-Za-z0-9_:]+)'
  foreach ($ln in $lines) { $msn = $snRx.Match($ln); if ($msn.Success) { $scriptName = $msn.Groups[1].Value; break } }

  $externalHandled = New-Object 'System.Collections.Generic.HashSet[string]'
  $ownerRx = [regex]'^\s*Event\s+([A-Za-z0-9_]+)\.([A-Za-z0-9_]+)\s*\('
  foreach ($ln in $lines) {
    $mo = $ownerRx.Match($ln)
    if ($mo.Success) {
      $owner = $mo.Groups[1].Value; $ename = $mo.Groups[2].Value
      if ($scriptName -and ($owner -ne $scriptName)) { [void]$externalHandled.Add($ename) }
    }
  }

  $externalReg = New-Object 'System.Collections.Generic.HashSet[string]'
  $regRx = [regex]'\bRegisterForCustomEvent\(\s*([^,]+?)\s*,\s*"([^"]+)"'
  foreach ($ln in $lines) {
    $mr = $regRx.Match($ln)
    if ($mr.Success) {
      $target = $mr.Groups[1].Value.Trim()
      $ename  = $mr.Groups[2].Value
      $isSelf = ($target -match '^(?i:self)\b')
$mentionsOwnType = $false
if ($scriptName) { $mentionsOwnType = $target -match ('(?i)\b' + [regex]::Escape($scriptName) + '\b') }
if (-not $isSelf -and -not $mentionsOwnType) { [void]$externalReg.Add($ename) }
    }
  }

  $declLineRx = [regex]'^\s*CustomEvent\s+([A-Za-z0-9_:]+)\s*$'
  $filtered = @()
  foreach ($ln2 in $newLines) {
    $md = $declLineRx.Match($ln2)
    if ($md.Success) {
      $nm = $md.Groups[1].Value
      if (-not $sent.Contains($nm) -and ($externalHandled.Contains($nm) -or $externalReg.Contains($nm))) {
        continue  # drop external-only decl
      }
    }
    $filtered += $ln2
  }
  $newLines = $filtered
} catch { }


$joined = ($newLines -join "`n") -replace "`n", "$NL"
  return ($joined.TrimEnd() + $NL)
}

  # Ensure Ifs are followed by EndIfs eventually
function Ensure-BalancedIfs([string]$text) {
  if ($null -eq $text) { return $text }
  $NL = "`r`n"
  $lf = $text -replace "`r`n?", "`n"
  $lines = $lf -split "`n", 0, 'SimpleMatch'

  $out = New-Object System.Collections.Generic.List[string]
  $ifDepth  = 0
  $lastCtrl = $null   # 'If' | 'ElseIf' | 'Else' | 'EndIf'
  $inBlock  = $false  # inside a Function/Event

  for ($i=0; $i -lt $lines.Count; $i++) {
    $ln   = $lines[$i]
    $code = [string](Get-CodePortion $ln)

    # ---- Block start: reset per-block state ----
    if (Is-FirstToken $code 'Function' -or Is-FirstToken $code 'Event') {
      $inBlock  = $true
      $ifDepth  = 0
      $lastCtrl = $null
      $out.Add($ln)
      continue
    }

    # ---- Block end: optionally close dangling Ifs for THIS block only ----
    if (Is-FirstToken $code 'EndFunction' -or Is-FirstToken $code 'EndEvent') {
      if ($inBlock -and $ifDepth -gt 0 -and ($lastCtrl -eq 'If' -or $lastCtrl -eq 'ElseIf' -or $lastCtrl -eq 'Else')) {
        while ($ifDepth -gt 0) { $out.Add('EndIf'); $ifDepth-- }
      }
      $out.Add($ln)
      # Reset block state after closing
      $inBlock  = $false
      $ifDepth  = 0
      $lastCtrl = $null
      continue
    }

    if ([string]::IsNullOrWhiteSpace($code)) { $out.Add($ln); continue }

    if (Is-FirstToken $code 'EndIf')  { if ($ifDepth -gt 0) { $ifDepth-- }; $lastCtrl = 'EndIf';  $out.Add($ln); continue }
    if (Is-FirstToken $code 'If')     { $ifDepth++;                       $lastCtrl = 'If';      $out.Add($ln); continue }
    if (Is-FirstToken $code 'ElseIf') {                                    $lastCtrl = 'ElseIf';  $out.Add($ln); continue }
    if (Is-FirstToken $code 'Else')   {                                    $lastCtrl = 'Else';    $out.Add($ln); continue }

    $out.Add($ln)
  }

  # EOF safety: only if we're still inside an open block AND the last control suggests an open branch
  if ($inBlock -and $ifDepth -gt 0 -and ($lastCtrl -eq 'If' -or $lastCtrl -eq 'ElseIf' -or $lastCtrl -eq 'Else')) {
    while ($ifDepth -gt 0) { $out.Add('EndIf'); $ifDepth-- }
  }

  $joined = ($out -join "`n") -replace "`n", $NL
  return ($joined.TrimEnd() + $NL)
}

  # Ensure the final Function is followed by EndFunction eventually
function Ensure-BlockClosures([string]$text) {
  if ($null -eq $text) { return $text }
  $NL = "`r`n"
  $lf = $text -replace "`r`n?", "`n"
  $lines = $lf -split "`n", 0, 'SimpleMatch'

  # Track only top-level Function/Event blocks (we do not try to fix mid-file, only at EOF)
  $funcDepth  = 0
  $eventDepth = 0
  foreach ($ln in $lines) {
    $code = [string](Get-CodePortion $ln)

    # Count Function blocks unless this SAME LINE declares a Native function (blockless)
    if (Is-FirstToken $code 'Function') {
      $isNativeOnSameLine = [System.Text.RegularExpressions.Regex]::IsMatch(
        $ln,
        '^\s*Function\b[^\r\n]*\bNative\b',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
      )
      if (-not $isNativeOnSameLine) { $funcDepth++ }
      continue
    }

    if (Is-FirstToken $code 'EndFunction') {
      if ($funcDepth -gt 0) { $funcDepth-- }
      continue
    }

    # Event handling unchanged (no Native special-case for events)
    if (Is-FirstToken $code 'Event') {
      $eventDepth++
      continue
    }

    if (Is-FirstToken $code 'EndEvent') {
      if ($eventDepth -gt 0) { $eventDepth-- }
      continue
    }
  }

  # If both are balanced, or both are unbalanced, do nothing (too ambiguous)
  if ( ($funcDepth -le 0 -and $eventDepth -le 0) -or ($funcDepth -gt 0 -and $eventDepth -gt 0) ) {
    return ($lf -replace "`n", $NL)
  }

  # Append only the needed closures at EOF; we assume missing only at the very end.
  $out = New-Object System.Collections.Generic.List[string]
  $out.AddRange($lines)

  if ($eventDepth -gt 0 -and $funcDepth -eq 0) {
    while ($eventDepth -gt 0) { $out.Add('EndEvent'); $eventDepth-- }
  } elseif ($funcDepth -gt 0 -and $eventDepth -eq 0) {
    while ($funcDepth -gt 0) { $out.Add('EndFunction'); $funcDepth-- }
  }

  $joined = ($out -join "`n") -replace "`n", $NL
  return ($joined.TrimEnd() + $NL)
}





function Sanitize-EventName([string]$name) {
  if ($null -eq $name) { return $name }
  $idx = $name.LastIndexOf(':')
  if ($idx -ge 0 -and $idx + 1 -lt $name.Length) { return $name.Substring($idx + 1) }
  return $name
}



function Transform-FragmentText([string]$raw) {
  if (-not $raw) { return $raw }

  # Normalize to LF using .NET (avoid PS operator arity pitfalls)
  $txt = ([string]$raw).Replace("`r`n","`n").Replace("`r","`n")

  $rxFunc = New-Object System.Text.RegularExpressions.Regex '^\s*Function\s+([A-Za-z0-9_]+)\s*\(',
      ([System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Multiline)
  $rxEndF = New-Object System.Text.RegularExpressions.Regex '^\s*EndFunction\s*$',
      ([System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Multiline)

  function _GetTopLevelFunctions([string]$text) {
    $list = @()
    $pos  = 0
    while ($true) {
      $m = $rxFunc.Match($text, $pos)
      if (-not $m.Success) { break }
      $name     = $m.Groups[1].Value
      $sigStart = $m.Index
      $mEnd = $rxEndF.Match($text, $m.Index + $m.Length)
      if (-not $mEnd.Success) { break }
      $block = $text.Substring($sigStart, $mEnd.Index + $mEnd.Length - $sigStart)
      $list += [pscustomobject]@{ Name = $name; Block = $block }
      $pos = $mEnd.Index + $mEnd.Length
    }
    ,$list
  }

  # Match property declarations, including array types like "Scene[] Property X"
  $rxPropLine = New-Object System.Text.RegularExpressions.Regex '^\s*[A-Za-z0-9_:]+(?:\[\])?\s+Property\b',
      ([System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Multiline)
  $rxPropName = New-Object System.Text.RegularExpressions.Regex '^\s*[A-Za-z0-9_:]+(?:\[\])?\s+Property\s+([A-Za-z0-9_]+)\b',
      ([System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Multiline)

  function _ExtractPropertyLines([string]$text) {
    $lines = $text.Split("`n")
    $props = New-Object System.Collections.Generic.List[string]
    foreach ($ln in $lines) {
      if ($rxPropLine.IsMatch($ln)) {
        $props.Add($ln)
      }
    }
    $props
  }

  # Quick exit if no fragments
  if (-not [System.Text.RegularExpressions.Regex]::IsMatch($txt, '^\s*Function\s+Fragment_', 
        [System.Text.RegularExpressions.RegexOptions]::Multiline)) {
    return $raw
  }

  # Record original ScriptName & detect Packages fragments (to preserve Extends Package)
  $scriptNameLine = $null
  $mScript = [System.Text.RegularExpressions.Regex]::Match($txt, '^\s*ScriptName\s+([^\r\n]+)', 
               [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Multiline)
  if ($mScript.Success) { $scriptNameLine = $mScript.Value }
  $isPackages = ($scriptNameLine -ne $null) -and ($scriptNameLine -match 'Fragments:Packages:')

  # Gather property lines from original
  $propLines = _ExtractPropertyLines $txt

  # Remove ONLY the original property lines from the working body (we'll re-emit later)
  $lf = $txt
  if ($propLines.Count -gt 0) {
    $all = New-Object System.Collections.Generic.List[string]
    $srcLines = $lf.Split("`n")
    # Trim-based match to be robust against whitespace
    $propSet  = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($p in $propLines) { [void]$propSet.Add(([string]$p).Trim()) }
    foreach ($ln in $srcLines) {
      if ($propSet.Contains(([string]$ln).Trim())) { continue }
      $all.Add($ln)
    }
    $lf = ($all -join "`n")
  }

  # Extract functions and partition
  $allFuncs = _GetTopLevelFunctions $lf
  $fragFuncs   = @()
  $helperFuncs = @()
  foreach ($f in $allFuncs) {
    if ([System.Text.RegularExpressions.Regex]::IsMatch($f.Name, '^(?i)Fragment_')) { $fragFuncs += $f } else { $helperFuncs += $f }
  }

  $NL = "`r`n"
  $out = New-Object System.Text.StringBuilder
  # Handle Champollion banner for fragments
  [void]$out.AppendLine('; Decompiled by Champollion and processed by Decompiled_PSC_Repair by LBGSHI')
  [void]$out.AppendLine('')
  [void]$out.AppendLine(';BEGIN FRAGMENT CODE - Do not edit anything between this and the end comment')
  if ($scriptNameLine) {
    if ($isPackages -and ($scriptNameLine -notmatch '\bExtends\s+Package\b')) {
      $m = [System.Text.RegularExpressions.Regex]::Match($scriptNameLine, '^\s*ScriptName\s+([A-Za-z0-9_:]+)\s+Extends\s+([A-Za-z0-9_]+)(.*)$',
           [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
      if ($m.Success) {
        $rest = $m.Groups[3].Value
        $scriptNameLine = ('ScriptName ' + $m.Groups[1].Value + ' Extends Package' + $rest)
      }
    }
    [void]$out.AppendLine($scriptNameLine)
    [void]$out.AppendLine('')
  }
  $fragIdx = 0

  foreach ($f in $fragFuncs) {
    [void]$out.AppendLine(';BEGIN FRAGMENT ' + $f.Name)

    # Insert ;BEGIN CODE after Function signature
    $pattern = '^\s*Function\s+[^\r\n]+'
    $options = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Multiline
    $funcWithBegin = [System.Text.RegularExpressions.Regex]::Replace($f.Block, $pattern, 
      { param($m) $m.Value + "`n;BEGIN CODE" }, $options)

    $funcWithBegin = $funcWithBegin.TrimStart()
    # Strip trailing EndFunction; we re-emit
    if ([System.Text.RegularExpressions.Regex]::IsMatch($funcWithBegin, '\n\s*EndFunction\s*$', 
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
      $funcWithBegin = [System.Text.RegularExpressions.Regex]::Replace($funcWithBegin, '\n\s*EndFunction\s*$','',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    }

    [void]$out.Append($funcWithBegin.TrimEnd())
    [void]$out.AppendLine()
    [void]$out.AppendLine(';END CODE')
    [void]$out.AppendLine('EndFunction')
    [void]$out.AppendLine(';END FRAGMENT')
    $fragIdx++
    if ($fragIdx -lt $fragFuncs.Count) { [void]$out.AppendLine('') }
  }

  [void]$out.AppendLine('')
  [void]$out.AppendLine(';END FRAGMENT CODE - Do not edit anything between this and the begin comment')
  [void]$out.AppendLine('')

  # Preserve helper functions verbatim
  if ($helperFuncs.Count -gt 0) {
    [void]$out.AppendLine(';-- Helper functions (preserved) -----------------------')
    foreach ($f in $helperFuncs) {
      [void]$out.AppendLine($f.Block.TrimEnd())
      [void]$out.AppendLine('')
    }
  }

  # Append properties at the end (dedupe by property name if any already present)
  if ($propLines.Count -gt 0) {
    $outText = $out.ToString()
    $presentNames = New-Object 'System.Collections.Generic.HashSet[string]'
    $m2 = $rxPropName.Match($outText)
    while ($m2.Success) {
      [void]$presentNames.Add($m2.Groups[1].Value.ToLower())
      $m2 = $m2.NextMatch()
    }

    $toWrite = New-Object System.Collections.Generic.List[string]
    foreach ($p in $propLines) {
      $mx = $rxPropName.Match($p)
      if ($mx.Success) {
        $name = $mx.Groups[1].Value.ToLower()
        if (-not $presentNames.Contains($name)) {
          $toWrite.Add($p)
          [void]$presentNames.Add($name)
        }
      } else {
        $toWrite.Add($p)
      }
    }

    if ($toWrite.Count -gt 0) {
      [void]$out.AppendLine(';-- Properties --------------------------------------')
      foreach ($p in $toWrite) { [void]$out.AppendLine($p) }
      [void]$out.AppendLine('')
    }
  }

  $out.ToString()
}



# Promote simple-identifier senders to Actor when local map says Actor.
# Runs after Fix-EventRegistrations and Fix-RemoteEventCasts so we can override generic ObjectReference.
function Promote-ActorCasts([string]$text) {
  if ($null -eq $text) { return $text }
  $lf    = $text -replace "`r`n?", "`n"
  $lines = $lf -split "`n", 0, 'SimpleMatch'

  for ($i = 0; $i -lt $lines.Length; $i++) {
    $ln = $lines[$i]

    if ($ln -notmatch '(?:^|\s)(?:Self\.)?(?:Un)?RegisterForRemoteEvent\(') { continue }

    # Extract the full first-argument expression up to the comma
    $mArg = [regex]::Match($ln, '(?:^|\s)(?:Self\.)?(?:Un)?RegisterForRemoteEvent\(\s*(.+?)\s*,')
    if (-not $mArg.Success) { continue }
    $expr = $mArg.Groups[1].Value

    # Identify a simple identifier or a bracketed index expr
    $mId  = [regex]::Match($expr, '^(?:Self\.)?([A-Za-z_][A-Za-z0-9_]*)\b')
    $mIdx = [regex]::Match($expr, '^([A-Za-z_][A-Za-z0-9_]*\[[^\]]+\])')
    $key  = $null
    if ($mIdx.Success) { $key = $mIdx.Groups[1].Value }
    elseif ($mId.Success) { $key = $mId.Groups[1].Value }
    else { continue }

    # Find enclosing Event/Function block
    $evStart  = $i
    $blockType = $null
    while ($evStart -ge 0) {
      $hdr = $lines[$evStart]
      if ($hdr -match '^\s*Event\b')    { $blockType = 'Event'; break }
      if ($hdr -match '^\s*Function\b') { $blockType = 'Function'; break }
      $evStart--
    }
    if ($null -eq $blockType) { continue }
    $evEnd = $i
    if ($blockType -eq 'Event') {
      while ($evEnd -lt $lines.Length -and ($lines[$evEnd] -notmatch '^\s*EndEvent\b')) { $evEnd++ }
    } else {
      while ($evEnd -lt $lines.Length -and ($lines[$evEnd] -notmatch '^\s*EndFunction\b')) { $evEnd++ }
    }

    $localMap = Get-LocalTypeMap -Lines $lines -EventStartIndex $evStart -EventEndIndex $evEnd -GlobalPropsTypeMap @{}
    if (-not $localMap.ContainsKey($key)) { continue }
    $t = $localMap[$key]
    if ($t -ne 'Actor') { continue }

    # Upgrade/insert cast to Actor for this expr
    if ($expr -match '\bas\s+[A-Za-z0-9_:]+\b') {
      $newExpr = [regex]::Replace($expr, '\bas\s+[A-Za-z0-9_:]+\b', 'as Actor')
    } else {
      $newExpr = ($expr.TrimEnd() + ' as Actor')
    }

    # Splice back into the line
    $patternExpr = [regex]::Escape($expr)
    $ln = [regex]::Replace($ln, $patternExpr, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $newExpr }, 1)

    $lines[$i] = $ln
  }

  $joined = ($lines -join "`n") -replace "`n", [Environment]::NewLine
  return $joined
}



# Promote 'as ScriptObject' to 'as Actor' for distance registration APIs
# when the argument expression is a simple identifier or array index whose type is Actor
# in the enclosing Event/Function.
function Promote-ActorCastsInDistanceRegs([string]$text) {
  if ($null -eq $text) { return $text }
  $lf    = $text -replace "`r`n?", "`n"
  $lines = $lf -split "`n", 0, 'SimpleMatch'

  # Targets (prefix-insensitive): RegisterForDistanceLessThanEvent, RegisterForDistanceGreaterThanEvent, RegisterForDistanceBetweenEvent
  $rxCall = '(?:^|\s)(?:Self\.)?RegisterForDistance(?:LessThan|GreaterThan|Between)Event\('

  for ($i = 0; $i -lt $lines.Length; $i++) {
    $ln = $lines[$i]
    if ($ln -notmatch $rxCall) { continue }

    # Capture first two argument expressions (non-greedy up to commas)
    $m = [regex]::Match($ln, $rxCall + '\s*(.+?)\s*,\s*(.+?)\s*,')
    if (-not $m.Success) { continue }
    $arg1 = $m.Groups[1].Value
    $arg2 = $m.Groups[2].Value

    # Helper to compute a map key from an expression
    function __key([string]$expr) {
      $mIdx = [regex]::Match($expr, '^\s*([A-Za-z_][A-Za-z0-9_]*\[[^\]]+\])')
      if ($mIdx.Success) { return $mIdx.Groups[1].Value }
      $mId  = [regex]::Match($expr, '^(?:Self\.)?([A-Za-z_][A-Za-z0-9_]*)\b')
      if ($mId.Success) { return $mId.Groups[1].Value }
      return $null
    }

    $k1 = __key $arg1
    $k2 = __key $arg2
    if (-not $k1 -and -not $k2) { continue }

    # Find enclosing Event/Function block
    $evStart  = $i
    $blockType = $null
    while ($evStart -ge 0) {
      $hdr = $lines[$evStart]
      if ($hdr -match '^\s*Event\b')    { $blockType = 'Event'; break }
      if ($hdr -match '^\s*Function\b') { $blockType = 'Function'; break }
      $evStart--
    }
    if ($null -eq $blockType) { continue }
    $evEnd = $i
    if ($blockType -eq 'Event') {
      while ($evEnd -lt $lines.Length -and ($lines[$evEnd] -notmatch '^\s*EndEvent\b')) { $evEnd++ }
    } else {
      while ($evEnd -lt $lines.Length -and ($lines[$evEnd] -notmatch '^\s*EndFunction\b')) { $evEnd++ }
    }

    $localMap = Get-LocalTypeMap -Lines $lines -EventStartIndex $evStart -EventEndIndex $evEnd -GlobalPropsTypeMap @{}

    # Function to upgrade 'as ScriptObject' -> 'as Actor' when local map says Actor
    function __upgrade([string]$expr, [string]$key) {
      if (-not $key) { return $expr }
      if (-not $localMap.ContainsKey($key)) { return $expr }
      if ($localMap[$key] -ne 'Actor') { return $expr }
      if ($expr -match '\bas\s+ScriptObject\b') {
        return [regex]::Replace($expr, '\bas\s+ScriptObject\b', 'as Actor')
      }
      return $expr
    }

    $newArg1 = __upgrade $arg1 $k1
    $newArg2 = __upgrade $arg2 $k2

    if ($newArg1 -ne $arg1 -or $newArg2 -ne $arg2) {
      # Replace only the matched two-arg prefix to preserve the rest of the line
      $prefixPattern = [regex]::Escape($m.Groups[1].Value) + '\s*,\s*' + [regex]::Escape($m.Groups[2].Value)
      $replacement   = [regex]::Escape($newArg1) + ', ' + [regex]::Escape($newArg2)
      # We need a literal replacement, so use MatchEvaluator to unescape
      $ln = [regex]::Replace($ln, $prefixPattern, { param($mm) $newArg1 + ', ' + $newArg2 }, 1)
      $lines[$i] = $ln
    }
  }

  $joined = ($lines -join "`n") -replace "`n", [Environment]::NewLine
  return $joined
}


# Ensure Register/Unregister use consistent sender cast types per event+sender
function Fix-EventSenderTypeConsistency([string]$text) {
  if ($null -eq $text) { return $text }
  $NL = "`r`n"
  $lf = $text -replace "`r`n?", "`n"
  $lines = $lf -split "`n", 0, 'SimpleMatch'

  # Map of (kind|event|senderExprNormalized) -> preferredType (non ScriptObject if seen)
  $pref = @{}
  function Normalize-Sender($s) {
    if ($null -eq $s) { return "" }
    $t = ($s -replace '\s+', ' ').Trim()
    # strip harmless Self. prefix for matching symmetry
    if ($t -match '^(?i)Self\.(.+)$') { $t = $Matches[1] }
    return $t
  }

  $rx = [regex]'(?ix)
    ^\s*
    (?:(?:Self)\.)?
    (?<call>RegisterForCustomEvent|UnregisterForCustomEvent|RegisterForRemoteEvent|UnregisterForRemoteEvent)
    \s*\(
      \s*(?<sender>[^,()]+?)\s*
      (?:\s+as\s+(?<type>[A-Za-z_][A-Za-z0-9_]*))?
      \s*,\s*"
      (?<event>[^"]+)
      "\s*\)
  '

  # Pass 1: learn preferred types from any explicit casts
  for ($i=0; $i -lt $lines.Count; $i++) {
    $ln = $lines[$i]
    $m = $rx.Match($ln)
    if (-not $m.Success) { continue }
    $call   = $m.Groups['call'].Value
    $sender = Normalize-Sender $m.Groups['sender'].Value
    $etype  = $m.Groups['type'].Value
    $event  = $m.Groups['event'].Value
    $kind   = if ($call -match 'Remote') { 'remote' } else { 'custom' }
    $key    = "$kind|$event|$sender"
    if (-not [string]::IsNullOrEmpty($etype) -and $etype -ne 'ScriptObject') {
      $pref[$key] = $etype
    } elseif (-not $pref.ContainsKey($key)) {
      # initialize to ScriptObject if nothing else learned yet
      $pref[$key] = 'ScriptObject'
    }
  }

  # Pass 2: rewrite to preferred (non-ScriptObject) type when known; insert 'as' if missing
  for ($i=0; $i -lt $lines.Count; $i++) {
    $ln = $lines[$i]
    $m = $rx.Match($ln)
    if (-not $m.Success) { continue }
    $call   = $m.Groups['call'].Value
    $senderRaw = $m.Groups['sender'].Value
    $sender = Normalize-Sender $senderRaw
    $etype  = $m.Groups['type'].Value
    $event  = $m.Groups['event'].Value
    $kind   = if ($call -match 'Remote') { 'remote' } else { 'custom' }
    $key    = "$kind|$event|$sender"

    if ($pref.ContainsKey($key) -and $pref[$key] -ne 'ScriptObject') {
      $want = $pref[$key]
      if ([string]::IsNullOrEmpty($etype)) {
        # insert ' as <want>' before , "event"
        $lines[$i] = [regex]::Replace($ln, '(\s*,\s*")', ' as ' + $want + '$1', 1)
      } elseif ($etype -ne $want) {
        # replace existing type token (only in this cast position)
        $lines[$i] = [regex]::Replace($ln, '\bas\s+[A-Za-z_]\w*(?=\s*,\s*")', 'as ' + $want, 1)
      }
    }
  }

  return (($lines -join "`n") -replace "`n", $NL)
}
function Prune-EmptyGuardBlocks {
    param([string]$text)
    if ($null -eq $text) { return $text }
    $NL = "`r`n"
    $lf = $text -replace "`r`n?", "`n"
    $lines = $lf -split "`n", 0, 'SimpleMatch'

    $out = New-Object System.Collections.Generic.List[string]
    $inFunc = $false
    $stack = New-Object 'System.Collections.Generic.List[int]'  # store start index in $out for each block start

    for ($i=0; $i -lt $lines.Count; $i++) {
        $raw  = $lines[$i]
        $code = [string](Get-CodePortion $raw)
        if ($code -imatch '^\s*(?:[A-Za-z0-9_\[\]:]+\s+)*Function\b' -or $code -imatch '^\s*Event\b') { $inFunc = $true; $stack.Clear() }
        if ($code -imatch '^\s*EndFunction\b' -or $code -imatch '^\s*EndEvent\b') { $inFunc = $false; $stack.Clear() }

        if ($inFunc) {
            if ($code -imatch '^\s*(TryLockGuard|LockGuard|TryGuard|Guard)\s+([A-Za-z0-9_]+)\b') {
                $stack.Add($out.Count) | Out-Null
                $out.Add($raw)
                continue
            }
            if ($code -imatch '^\s*End(TryLockGuard|LockGuard|Guard)\b') {
                $startIdx = $null
                if ($stack.Count -gt 0) { $startIdx = $stack[$stack.Count-1]; $stack.RemoveAt($stack.Count-1) }
                # If the region between start and this end contains no code (only blank/comment lines), comment both
                $hasCode = $false
                if ($startIdx -ne $null) {
                    for ($j = $startIdx + 1; $j -lt $out.Count; $j++) {
                        $mid = [string](Get-CodePortion $out[$j])
                        if ($mid -and $mid.Trim() -ne '') { $hasCode = $true; break }
                    }
                }
                if (-not $hasCode -and $startIdx -ne $null) {
                    $out[$startIdx] = '; ' + $out[$startIdx]
                    $out.Add('; ' + $raw)
                } else {
                    $out.Add($raw)
                }
                continue
            }
        }
        $out.Add($raw)
    }

    ($out -join "`n") -replace "`n", $NL
}




function Fix-GetAllMatchingStructs([string]$text) {
  if ($null -eq $text) { return $text }
  # Replace whole-word GetMatchingStructs with GetAllMatchingStructs
  return ($text -replace '\bGetMatchingStructs\b', 'GetAllMatchingStructs')
}



function Comment-UnusedHeaderGuards {
  param([string]$text)

  if ($null -eq $text) { return $text }
  $NL = "`r`n"
  $lf = $text -replace "`r`n?", "`n"
  $lines = $lf -split "`n", 0, 'SimpleMatch'

  # Identify top-level header guard declarations (outside any Function/Event)
  $headerDecls = New-Object 'System.Collections.Generic.List[object]'
  $inBlock = $false
  for ($i=0; $i -lt $lines.Count; $i++) {
    $code = [string](Get-CodePortion $lines[$i])
    if ($code -imatch '^\s*(?:[A-Za-z0-9_\[\]:]+\s+)*Function\b' -or $code -imatch '^\s*Event\b') { $inBlock = $true; continue }
    if ($code -imatch '^\s*EndFunction\b' -or $code -imatch '^\s*EndEvent\b') { $inBlock = $false; continue }
    if (-not $inBlock) {
      if ($null -ne $Matches) { try { $Matches.Clear() } catch {} }
      if ($code -imatch '^\s*Guard\s+([A-Za-z0-9_]+)\b') {
        $g = $Matches[1]
        $headerDecls.Add([pscustomobject]@{ Index = $i; Name = $g }) | Out-Null
      }
    }
  }
  if ($headerDecls.Count -eq 0) { return $text }

  # Build a set of guards referenced by properties' RequiresGuard(...)
  $guardsRequired = New-Object 'System.Collections.Generic.HashSet[string]'
  $rxReq = [regex]'(?im)\bRequiresGuard\(\s*([A-Za-z0-9_]+)\s*\)'
  foreach ($m in $rxReq.Matches($lf)) {
    [void]$guardsRequired.Add($m.Groups[1].Value.ToLowerInvariant())
  }

  # For each header-declared guard, keep it if:
  #  (a) It appears in ANY LockGuard/TryLockGuard/Guard line anywhere in the file body (beyond the header declaraion), OR
  #  (b) Any property declares RequiresGuard(<name>)
  # Else, comment it out as truly unused.
  $out = $lines.Clone()
  foreach ($decl in $headerDecls) {
    $name = $decl.Name
    $low  = ([string]$name).ToLowerInvariant()

    # Scan whole file for usage lines
    $usageRx = [regex]('(?im)^\s*(?:LockGuard|TryLockGuard|Guard)\s+' + [regex]::Escape($name) + '\b')
    $allUsages = $usageRx.Matches($lf)
    $usedCount = 0
    foreach ($um in $allUsages) {
      # Ignore if this match corresponds to the header declaration line itself
      $lineIdx = ($lf.Substring(0, $um.Index) -replace '[^\n]').Length  # quick line estimate: count newlines
      # Fallback simple check: if header line text contains the same, skip exactly that one index
      if ($lineIdx -ne $decl.Index) { $usedCount++ }
    }

    $hasPropReq = $guardsRequired.Contains($low)

    if ($usedCount -gt 0 -or $hasPropReq) {
      # Keep as-is
      continue
    } else {
      # Comment it out once; preserve any trailing comment
      $orig = $out[$decl.Index]
      if ($orig -notmatch '^\s*;') {
        $out[$decl.Index] = ($orig -replace '^\s*', '$0; ') + ' (unused header guard)'
      }
    }
  }

  return (($out -join "`n") -replace "`n", $NL)
}



function Add-ProtectsFunctionLogicForLogicGuards {
  param([string]$text)
  if ($null -eq $text) { return $text }
  $NL = "`r`n"
  $lf = $text -replace "`r`n?", "`n"
  $lines = $lf -split "`n", 0, 'SimpleMatch'


  # Recognize RequiresGuard on properties (incl. arrays/namespaced), functions, and events ---
  $guardsRequired = New-Object 'System.Collections.Generic.HashSet[string]'
  $rxPropReq = [regex]'(?im)^\s*(?:[A-Za-z0-9_:\[\]]+\s+)?Property\s+[A-Za-z0-9_]+\b.*?\bRequiresGuard\(\s*([A-Za-z0-9_]+)\s*\)'
  foreach ($mreq in $rxPropReq.Matches($lf)) { [void]$guardsRequired.Add($mreq.Groups[1].Value.ToLowerInvariant()) }
  $rxFuncReq = [regex]'(?im)^\s*(?:[A-Za-z0-9_:\[\]]+\s+)?Function\s+[A-Za-z0-9_]+\s*\([^)]*\).*?\bRequiresGuard\(\s*([A-Za-z0-9_]+)\s*\)'
  foreach ($mreq in $rxFuncReq.Matches($lf)) { [void]$guardsRequired.Add($mreq.Groups[1].Value.ToLowerInvariant()) }
  $rxEvtReq = [regex]'(?im)^\s*Event\s+[A-Za-z0-9_]+\s*\([^)]*\).*?\bRequiresGuard\(\s*([A-Za-z0-9_]+)\s*\)'
  foreach ($mreq in $rxEvtReq.Matches($lf)) { [void]$guardsRequired.Add($mreq.Groups[1].Value.ToLowerInvariant()) }

  # Header guard declarations (outside functions/events)
  $headerDecls = @()  # @{ Index; Name }
  $inHeader = $true
  for ($i=0; $i -lt $lines.Count; $i++) {
    $code = [string](Get-CodePortion $lines[$i])
    if ($code -imatch '^\s*(?:[A-Za-z0-9_\[\]:]+\s+)*Function\b' -or $code -imatch '^\s*Event\b') { $inHeader = $false; break }
    if ($code -imatch '^\s*Guard\s+([A-Za-z0-9_]+)\b') {
      $headerDecls += ,@{ Index = $i; Name = $Matches[1] }
    }
  }
  if ($headerDecls.Count -eq 0) { return $text }

  # Collect properties that declare RequiresGuard(G)
  $reqProps = @()  # list of @{ NameLow; GuardLow; DeclIndex }
  for ($i=0; $i -lt $lines.Count; $i++) {
    $code = [string](Get-CodePortion $lines[$i])
    if ($code -imatch '^\s*(?:[A-Za-z0-9_\[\]:]+\s+)?Property\s+([A-Za-z0-9_]+)\b.*?\bRequiresGuard\(\s*([A-Za-z0-9_]+)\s*\)') {
      $reqProps += ,@{ NameLow = $Matches[1].ToLowerInvariant(); GuardLow = $Matches[2].ToLowerInvariant(); DeclIndex = $i }

    # Function with RequiresGuard
    if ($code -imatch '^\s*(?:[A-Za-z0-9_:\[\]]+)\s+Function\s+[A-Za-z0-9_]+\s*\([^)]*\).*?\bRequiresGuard\(\s*([A-Za-z0-9_]+)\s*\)') {
      $reqProps += ,@{ NameLow = ""; GuardLow = $Matches[1].ToLowerInvariant(); DeclIndex = $i }
    }
    # Event with RequiresGuard
    if ($code -imatch '^\s*Event\s+[A-Za-z0-9_]+\s*\([^)]*\).*?\bRequiresGuard\(\s*([A-Za-z0-9_]+)\s*\)') {
      $reqProps += ,@{ NameLow = ""; GuardLow = $Matches[1].ToLowerInvariant(); DeclIndex = $i }
    }

    }
  }

  # Build guard blocks and the properties referenced inside each block
  $blocks = @()  # list of @{ GuardLow; Props HashSet[string] }
  $stack  = New-Object 'System.Collections.Generic.List[object]'
  $inBody = $false
  for ($i=0; $i -lt $lines.Count; $i++) {
    $code = [string](Get-CodePortion $lines[$i])
    if ($code -imatch '^\s*(?:[A-Za-z0-9_\[\]:]+\s+)*Function\b' -or $code -imatch '^\s*Event\b') { $inBody = $true; continue }
    if ($code -imatch '^\s*EndFunction\b' -or $code -imatch '^\s*EndEvent\b') { $inBody = $false; continue }
    if (-not $inBody) { continue }

    if ($code -imatch '^\s*(TryLockGuard|LockGuard|Guard)\s+([A-Za-z0-9_]+)\b') {
      $g = $Matches[2].ToLowerInvariant()
      $hs = New-Object 'System.Collections.Generic.HashSet[string]'
      $stack.Add([pscustomobject]@{ GuardLow = $g; Props = $hs }) | Out-Null
      continue
    }
    if ($code -imatch '^\s*End(TryLockGuard|LockGuard|Guard)\b') {
      if ($stack.Count -gt 0) {
        $blk = $stack[$stack.Count-1]
        $stack.RemoveAt($stack.Count-1)
        $blocks += ,$blk
      }
      continue
    }

    if ($stack.Count -gt 0) {
      $low = ([string]$code).ToLowerInvariant()
      foreach ($p in $reqProps) {
        if ($low -match ('(^|[^A-Za-z0-9_])' + [regex]::Escape($p.NameLow) + '([^A-Za-z0-9_]|$)')) {
          $stack[$stack.Count-1].Props.Add($p.NameLow) | Out-Null
        }
      }
    }
  }

  $out = $lines.Clone()

  # Helper to add PFL to a header line
  function _AddPFL([string]$line) {
    if ($line -match '(?i)\bProtectsFunctionLogic\b') { return $line }
    $semi = $line.IndexOf(';')
    if ($semi -ge 0) {
      $codePart = $line.Substring(0, $semi).TrimEnd()
      $comment  = $line.Substring($semi)
      return $codePart + ' ProtectsFunctionLogic ' + $comment
    } else {
      return $line.TrimEnd() + ' ProtectsFunctionLogic'
    }
  }

  # For each header guard:
  #   if it is used in the body AND
  #   (a) no properties require it  -> add PFL (logic-only), OR
  #   (b) properties require it but there exists at least one lock block that references none of those required props
  #       -> treat as logic guard for the "other" uses: strip RequiresGuard from those props in this file and add PFL.
  foreach ($decl in $headerDecls) {
    $gName = $decl.Name
    $gLow  = $gName.ToLowerInvariant()
    $line  = $out[$decl.Index]

    # Is the guard used anywhere?
    $used = $false
    foreach ($blk in $blocks) { if ($blk.GuardLow -eq $gLow) { $used = $true; break } }
    if (-not $used) { continue }

    # Required props for this guard in this file
    $propsForG = @($reqProps | Where-Object { $_.GuardLow -eq $gLow })
    $hasReq = ($propsForG.Count -gt 0)

    if (-not $hasReq) {
      # Pure logic guard
      $out[$decl.Index] = _AddPFL $line
      continue
    }

    # There are required props; detect mixed usage: a block of this guard that doesn't reference any required prop
    $hasMixed = $false
    foreach ($blk in $blocks) {
      if ($blk.GuardLow -ne $gLow) { continue }
      $touchesAny = $false
      foreach ($p in $propsForG) {
        if ($blk.Props.Contains($p.NameLow)) { $touchesAny = $true; break }
      }
      if (-not $touchesAny) { $hasMixed = $true; break }
    }

    if ($hasMixed) {
      # Strip RequiresGuard from all those props in this file (harmonize down to logic guard)
      foreach ($p in $propsForG) {
        $iDecl = $p.DeclIndex
        $pline = $out[$iDecl]
        $semi = $pline.IndexOf(';')
        $codePart = $pline
$comment  = ""
if ($semi -ge 0) { $codePart = $pline.Substring(0, $semi); $comment = $pline.Substring($semi) }
$codePart2 = [regex]::Replace($codePart, '(?i)\s*\bRequiresGuard\s*\(\s*[A-Za-z0-9_]+\s*\)', '')
        $out[$iDecl] = $codePart2.TrimEnd() + $comment
      }
      # And mark header as logic-only
      $out[$decl.Index] = _AddPFL $out[$decl.Index]
    }
  }

  return (($out -join "`n") -replace "`n", $NL)
}

function Strip-RequiresGuardWhenGuardIsPFL {
  param([string]$text)
  if ($null -eq $text) { return $text }
  $NL = "`r`n"
  $lf = $text -replace "`r`n?", "`n"
  $lines = $lf -split "`n", 0, 'SimpleMatch'

  # Collect header guards that explicitly have ProtectsFunctionLogic
  $pflGuards = New-Object 'System.Collections.Generic.HashSet[string]'
  $inBody = $false
  for ($i=0; $i -lt $lines.Count; $i++) {
    $code = [string](Get-CodePortion $lines[$i])
    if ($code -imatch '^\s*(?:[A-Za-z0-9_\[\]:]+\s+)*Function\b' -or $code -imatch '^\s*Event\b') { $inBody = $true; break }
    if ($code -imatch '^\s*Guard\s+([A-Za-z0-9_]+)\b.*\bProtectsFunctionLogic\b') {
      [void]$pflGuards.Add($Matches[1].ToLowerInvariant())
    }
  }
  if ($pflGuards.Count -eq 0) { return $text }

  # Remove RequiresGuard(<guard>) tokens for any properties that reference a PFL guard
  $out = $lines.Clone()
  $changed = $false
  for ($i=0; $i -lt $out.Count; $i++) {
    $line = $out[$i]
    $code = [string](Get-CodePortion $line)
    if ($code -imatch '^\s*(?:[A-Za-z0-9_\[\]:]+\s+)?Property\b' -and $code -imatch '\bRequiresGuard\(\s*([A-Za-z0-9_]+)\s*\)') {
      $g = $Matches[1].ToLowerInvariant()
      if ($pflGuards.Contains($g)) {
        $semi = $line.IndexOf(';')
        $codePart = $line
        $comment  = ""
        if ($semi -ge 0) { $codePart = $line.Substring(0, $semi); $comment = $line.Substring($semi) }
        $codePart2 = [regex]::Replace($codePart, '(?i)\s*\bRequiresGuard\s*\(\s*[A-Za-z0-9_]+\s*\)', '')
        $out[$i] = $codePart2.TrimEnd() + $comment
        $changed = $true
      }
    }
  }

  if (-not $changed) { return $text }
  return (($out -join "`n") -replace "`n", $NL)
}



function Ensure-FunctionRequiresGuard {
  param([string]$text)
  if ($null -eq $text) { return $text }
  $NL = "`r`n"
  $lf = $text -replace "`r`n?", "`n"
  $lines = $lf -split "`n", 0, 'SimpleMatch'

  $aliasTypes = @('referencealias','refcollectionalias')
  $primitiveTypes = @('int','bool','float','string')

  # Map properties that declare RequiresGuard(G), capturing their type and original name
  $propInfo = @{} # propLow -> @{ Guard; Type; Name }
  for ($i=0; $i -lt $lines.Count; $i++) {
    $code = [string](Get-CodePortion $lines[$i])
    if ($code -imatch '^\s*(?:([A-Za-z0-9_:\[\]]+)\s+)?Property\s+([A-Za-z0-9_]+)\b.*?\bRequiresGuard\(\s*([A-Za-z0-9_]+)\s*\)') {
      $typ     = $Matches[1]
      $pName   = $Matches[2]
      $gName   = $Matches[3]
      $ptype   = if ($null -ne $typ) { $typ.ToLowerInvariant() } else { '' }
      $propInfo[$pName.ToLowerInvariant()] = @{ Guard = $gName; Type = $ptype; Name = $pName }
    }
  }
  if ($propInfo.Count -eq 0) { return $text }

  $out = $lines.Clone()
  $inFunc = $false
  $funcStart = -1
  $funcReq = $false
  $unguardedRefs = $null
  $guardStack = $null
  $funcBodyStart = -1

  for ($i=0; $i -lt $lines.Count; $i++) {
    $code = [string](Get-CodePortion $lines[$i])

    if (-not $inFunc) {
      if ($code -imatch '^\s*(?:[A-Za-z0-9_:\[\]]+\s+)?Function\s+([A-Za-z0-9_]+)\s*\(') {
        $inFunc = $true
        $funcStart = $i
        $funcBodyStart = $i + 1
        $funcReq = ($code -match '(?i)\bRequiresGuard\(')
        $unguardedRefs = New-Object 'System.Collections.Generic.HashSet[string]'
        $guardStack = New-Object 'System.Collections.Generic.List[string]'
      }
      continue
    }

    # Track guard stack
    if ($code -imatch '^\s*(?:LockGuard|TryLockGuard|Guard)\s+([A-Za-z0-9_]+)\b') {
      $guardStack.Add($Matches[1]) | Out-Null
      continue
    }
    if ($code -imatch '^\s*End(?:LockGuard|TryLockGuard|Guard)\b') {
      if ($guardStack.Count -gt 0) { $guardStack.RemoveAt($guardStack.Count-1) }
      continue
    }

    # End of function -> decide annotation
    if ($code -imatch '^\s*EndFunction\b') {
      if (-not $funcReq) {
        $annotated = $false

        # Path A: unguarded structural refs (precise)
        if ($unguardedRefs.Count -gt 0) {
          $guards = New-Object System.Collections.Generic.HashSet[string]
          foreach ($pLow in $unguardedRefs) { [void]$guards.Add($propInfo[$pLow].Guard.ToLowerInvariant()) }
          if ($guards.Count -eq 1) {
            $only = $null; foreach ($g in $guards) { $only = $g; break }
            $origGuard = $null
            foreach ($pLow in $unguardedRefs) {
              $gCand = $propInfo[$pLow].Guard
              if ($gCand -and ($gCand.ToLowerInvariant() -eq $only)) { $origGuard = $gCand; break }
            }
            if ($null -ne $origGuard) {
              $line = $out[$funcStart]
              $out[$funcStart] = $line.TrimEnd() + ' RequiresGuard(' + $origGuard + ')'
              $annotated = $true
            }
          }
        }

        # Path B (fallback): structural property usage exists AND no guard for that guard appears anywhere in the function
        if (-not $annotated) {
          $funcEnd = $i
          $body = ($lines[$funcBodyStart..$funcEnd] -join $NL)
          $funcGuards = New-Object System.Collections.Generic.HashSet[string]
          foreach ($m in ([regex]'(?im)^\s*(?:LockGuard|TryLockGuard|Guard)\s+([A-Za-z0-9_]+)\b').Matches($body)) {
            [void]$funcGuards.Add($m.Groups[1].Value.ToLowerInvariant())
          }

          $candGuards = New-Object System.Collections.Generic.HashSet[string]
          foreach ($kv in $propInfo.GetEnumerator()) {
            $pLow = $kv.Key; $info = $kv.Value
            if ($aliasTypes -contains $info.Type -or $primitiveTypes -contains $info.Type) { continue }
            $pat = '(?i)\b' + [regex]::Escape($info.Name) + '\s*(?:\[|\.)'
            if ([regex]::IsMatch($body, $pat)) {
              $gLow = $info.Guard.ToLowerInvariant()
              if (-not $funcGuards.Contains($gLow)) { [void]$candGuards.Add($gLow) }
            }
          }
          if ($candGuards.Count -eq 1) {
            $only = $null; foreach ($g in $candGuards) { $only = $g; break }
            $orig = $null
            foreach ($kv in $propInfo.GetEnumerator()) {
              if ($kv.Value.Guard.ToLowerInvariant() -eq $only) { $orig = $kv.Value.Guard; break }
            }
            if ($null -ne $orig) {
              $line = $out[$funcStart]
              $out[$funcStart] = $line.TrimEnd() + ' RequiresGuard(' + $orig + ')'
            }
          }
        }
      }

      # reset state
      $inFunc = $false
      $funcStart = -1
      $funcBodyStart = -1
      $funcReq = $false
      $unguardedRefs = $null
      continue
    }

    # While not inside a guard region: collect structural refs
    if ($guardStack.Count -eq 0) {
      foreach ($kv in $propInfo.GetEnumerator()) {
        $pLow = $kv.Key; $info = $kv.Value
        if ($aliasTypes -contains $info.Type -or $primitiveTypes -contains $info.Type) { continue }
        $pat = '(?i)\b' + [regex]::Escape($info.Name) + '\s*(?:\[|\.)'
        if ($code -match $pat) { [void]$unguardedRefs.Add($pLow) }
      }
    }
  }

  return ($out -join $NL)
}
function Ensure-FunctionRequiresGuardByInference {
  param([string]$text)
  if ($null -eq $text) { return $text }
  $NL = "`r`n"
  $lf = $text -replace "`r`n?", "`n"
  $lines = $lf -split "`n", 0, 'SimpleMatch'

  # 1) Collect property declarations (name -> type/index)
  $props = @{}  # lower -> @{ Name; Type; Index }
  for ($i=0; $i -lt $lines.Count; $i++) {
    $code = [string](Get-CodePortion $lines[$i])
    if ($code -imatch '^\s*(?:([A-Za-z0-9_:\[\]]+)\s+)?Property\s+([A-Za-z0-9_]+)\b') {
      $typ = $Matches[1]; $nm = $Matches[2]
      $ptype = if ($null -ne $typ) { $typ.ToLowerInvariant() } else { '' }
      $props[$nm.ToLowerInvariant()] = @{ Name=$nm; Type=$ptype; Index=$i }
    }
  }
  if ($props.Count -eq 0) { return $text }
  $aliasTypes = @('referencealias','refcollectionalias')
  $primitiveTypes = @('int','bool','float','string')

  # 2) Infer property->guard mapping by scanning Guard/LockGuard/TryLockGuard blocks anywhere in the file
  $propToGuard = @{}       # propLow -> guard (original case)
  $propToGuardMulti = @{}  # propLow -> HashSet of guards (to detect ambiguity)
  for ($i=0; $i -lt $lines.Count; $i++) {
    $code = [string](Get-CodePortion $lines[$i])
    if ($code -imatch '^\s*(?:LockGuard|TryLockGuard|Guard)\s+([A-Za-z0-9_]+)\b') {
      $gName = $Matches[1]
      $nest = 1; $j = $i + 1
      while ($j -lt $lines.Count -and $nest -gt 0) {
        $c2 = [string](Get-CodePortion $lines[$j])
        if ($c2 -match '^\s*(?:LockGuard|TryLockGuard|Guard)\b') { $nest++ }
        elseif ($c2 -match '^\s*End(?:LockGuard|TryLockGuard|Guard)\b') { $nest--; if ($nest -eq 0) { break } }
        else {
          foreach ($kv in $props.GetEnumerator()) {
            $pName = $kv.Value.Name
            $ptype = $kv.Value.Type
            if ($aliasTypes -contains $ptype -or $primitiveTypes -contains $ptype) { continue }
            $pat = '(?i)\b' + [regex]::Escape($pName) + '\s*(?:\[|\.)'
            if ($c2 -match $pat) {
              $pl = $pName.ToLowerInvariant()
              if (-not $propToGuardMulti.ContainsKey($pl)) {
                $set = New-Object 'System.Collections.Generic.HashSet[string]'
                $propToGuardMulti[$pl] = $set
              } else { $set = $propToGuardMulti[$pl] }
              [void]$set.Add($gName)
            }
          }
        }
        $j++
      }
      $i = $j
    }
  }
  foreach ($kv in $propToGuardMulti.GetEnumerator()) {
    $guards = $kv.Value
    if ($guards.Count -eq 1) {
      foreach ($g in $guards) { $propToGuard[$kv.Key] = $g; break }
    }
  }
  if ($propToGuard.Count -eq 0) { return $text }

  # Helper to strip RequiresGuard(Guard) from a header line
  function Strip-HeaderRequiresGuard([string]$line, [string]$guard) {
    return ($line -replace ('(?i)\s*RequiresGuard\(\s*' + [regex]::Escape($guard) + '\s*\)'), '')
  }

  # 3) Rebuild the file function-by-function to avoid index drift and stray inserts
  $out = New-Object 'System.Collections.Generic.List[string]'
  $i = 0
  while ($i -lt $lines.Count) {
    $code = [string](Get-CodePortion $lines[$i])
    if ($code -imatch '^\s*(?:[A-Za-z0-9_:\[\]]+\s+)?Function\s+([A-Za-z0-9_]+)\s*\(') {
      $funcName = $Matches[1]
      $hdrIdx = $i
      # find EndFunction
      $j = $i + 1
      while ($j -lt $lines.Count -and ([string](Get-CodePortion $lines[$j])) -notmatch '^\s*EndFunction\b') { $j++ }
      if ($j -ge $lines.Count) { 
        # malformed, just copy the rest
        while ($i -lt $lines.Count) { $out.Add($lines[$i]); $i++ }
        break
      }
      $endIdx = $j

      # slice
      $hdr = $lines[$hdrIdx]
      $body = $lines[($hdrIdx+1)..($endIdx-1)]
      $endLine = $lines[$endIdx]

      # Determine guards present in body
      $bodyText = ($body -join $NL)
      $funcGuards = New-Object 'System.Collections.Generic.HashSet[string]'
      foreach ($m in ([regex]'(?im)^\s*(?:LockGuard|TryLockGuard|Guard)\s+([A-Za-z0-9_]+)\b').Matches($bodyText)) {
        [void]$funcGuards.Add($m.Groups[1].Value.ToLowerInvariant())
      }

      # Determine which mapped guard(s) this function references via properties
      $cand = New-Object 'System.Collections.Generic.HashSet[string]'
      foreach ($kv in $propToGuard.GetEnumerator()) {
        $pLow = $kv.Key; $gName = $kv.Value
        $pName = $props[$pLow].Name
        $ptype = $props[$pLow].Type
        if ($aliasTypes -contains $ptype -or $primitiveTypes -contains $ptype) { continue }
        $pat = '(?i)\b' + [regex]::Escape($pName) + '\s*(?:\[|\.)'
        if ([regex]::IsMatch($bodyText, $pat)) {
          [void]$cand.Add($gName)
        }
      }

      $hasHeaderRG = ($hdr -match '(?i)\bRequiresGuard\(\s*([A-Za-z0-9_]+)\s*\)')
      $headerGuard = if ($hasHeaderRG) { $Matches[1] } else { '' }

      # Decide transformation
      $out.Add($null) # placeholder for header to set later
      $insertLock = $false
      $guardToUse = $null

      if ($cand.Count -eq 1) {
        foreach ($g in $cand) { $guardToUse = $g; break }
      }

      if ($funcName -match '^(?i)Private_') {
        # Private: ensure header RG, no body lock
        if ($guardToUse -and (-not $hasHeaderRG)) {
          $hdr = $hdr.TrimEnd() + ' RequiresGuard(' + ($guardToUse) + ')'
        }
      } else {
        # Public/external: prefer internal lock; strip header RG if present
        if ($hasHeaderRG) {
          $hdr = Strip-HeaderRequiresGuard $hdr $headerGuard
        }
        if ($guardToUse -and (-not $funcGuards.Contains($guardToUse.ToLowerInvariant()))) {
          $insertLock = $true
        }
      }

      # Write header
      $out[$out.Count-1] = $hdr

      # Maybe inject lock around body
      if ($insertLock -and $guardToUse) {
        # determine indentation
        $m = [regex]::Match($hdr, '^\s*')
        $indent = if ($m.Success) { $m.Value } else { '' }
        $out.Add($indent + '  LockGuard ' + $guardToUse)
        foreach ($ln in $body) { $out.Add($ln) }
        $out.Add($indent + '  EndLockGuard')
      } else {
        foreach ($ln in $body) { $out.Add($ln) }
      }

      # EndFunction
      $out.Add($endLine)

      # continue after function
      $i = $endIdx + 1
      continue
    }

    # Non-function line: copy
    $out.Add($lines[$i])
    $i++
  }

  return ($out.ToArray() -join $NL)
}
function Fix-SelfQualifiedLocalFunctionCalls {
  param([string]$text)
  if ($null -eq $text) { return $text }
  $NL = "`r`n"
  $lf = $text -replace "`r`n?", "`n"
  $lines = $lf -split "`n", 0, 'SimpleMatch'

  # Collect local function names declared in this script (typed or untyped)
  $funcNames = New-Object 'System.Collections.Generic.Dictionary[string,string]'
  for ($i=0; $i -lt $lines.Count; $i++) {
    $code = [string](Get-CodePortion $lines[$i])
    if ($code -imatch '^\s*(?:[A-Za-z0-9_:\[\]]+\s+)?Function\s+([A-Za-z0-9_]+)\s*\(') {
      $name = $Matches[1]
      $key = $name.ToLowerInvariant()
      if (-not $funcNames.ContainsKey($key)) { $funcNames[$key] = $name }
    }
  }
  if ($funcNames.Count -eq 0) { return $text }

  # Replace "Self.<LocalFunction>(" -> "<LocalFunction>(" for locally-declared functions only
  $changed = $false
  for ($i=0; $i -lt $lines.Count; $i++) {
    $orig = $lines[$i]
    $code = [string](Get-CodePortion $orig)
    if ($code -match '(?i)\bSelf\s*\.\s*([A-Za-z0-9_]+)\s*\(') {
      foreach ($kv in $funcNames.GetEnumerator()) {
        $fname = $kv.Value
        $pat = '(?i)\bSelf\s*\.\s*' + [regex]::Escape($fname) + '\s*\('
        $repl = $fname + '('
        $new = [regex]::Replace($orig, $pat, $repl)
        if ($new -ne $orig) {
          $orig = $new
          $changed = $true
        }
      }
    }
    $lines[$i] = $orig
  }

  if (-not $changed) { return $text }
  return ($lines -join $NL)
}

function Fix-RemoteEventScriptObjectCast {
  param([string]$text)
  if ($null -eq $text) { return $text }
  $NL = "`r`n"
  $lf = $text -replace "`r`n?", "`n"
  $lines = $lf -split "`n", 0, 'SimpleMatch'

  $changed = $false
  for ($i=0; $i -lt $lines.Count; $i++) {
    $orig = $lines[$i]
    $code = [string](Get-CodePortion $orig)
    if ($code -match '(?i)\b(Un)?RegisterForRemoteEvent\s*\(') {
      $new = [regex]::Replace($orig, '(?i)\b(RegisterForRemoteEvent|UnRegisterForRemoteEvent)\s*\(\s*([^,]+?)\s+as\s+ScriptObject\b', '$1($2')
      if ($new -ne $orig) { $lines[$i] = $new; $changed = $true }
    }
  }
  if (-not $changed) { return $text }
  return ($lines -join $NL)
}
function Restore-TrailingDefaultArgs {
  param([string]$text)
  if ($null -eq $text) { return $text }
  $NL = "`r`n"
  $lf = $text -replace "`r`n?", "`n"
  $lines = $lf -split "`n", 0, 'SimpleMatch'

  $primitives = @('int','float','bool','string')
  $changedAny = $false

  # Case-insensitive denylist of function names that must not get synthesized defaults
  $NoDefaultParamFunctions = @('processfloortravelrequest')

  for ($i=0; $i -lt $lines.Count; $i++) {
    $orig = $lines[$i]
    $code = [string](Get-CodePortion $orig)

    # Only match single-line function headers
    if ($code -imatch '^\s*(?:[A-Za-z0-9_:\[\]]+\s+)?Function\s+([A-Za-z0-9_]+)\s*\(([^)]*)\)(.*)$') {
      $fname = $Matches[1]
      $fnameLow = $fname.ToLowerInvariant()
      $paramText = $Matches[2]

      # Skip denylisted functions entirely
      if ($NoDefaultParamFunctions -contains $fnameLow) {
        continue
      }

      # Tokenize params by commas
      $parts = @()
      if ($paramText.Trim().Length -gt 0) { $parts = $paramText -split ',' }
      if ($parts.Count -eq 0) { continue }

      # Parse params
      $paramObjs = @()
      $parseFailed = $false
      foreach ($p in $parts) {
        $p2 = $p.Trim()
        if ($p2 -eq '') { continue }
        $m = [regex]::Match($p2, '^\s*([A-Za-z0-9_:\[\]]+)\s+([A-Za-z0-9_]+)(\s*=\s*[^,]+)?\s*$', 'IgnoreCase')
        if (-not $m.Success) { $parseFailed = $true; break }
        $paramObjs += ,@{ Type=$m.Groups[1].Value; Name=$m.Groups[2].Value; Default=$m.Groups[3].Value }
      }
      if ($parseFailed -or $paramObjs.Count -eq 0) { continue }

      # Add defaults right-to-left to trailing params
      $changedLocal = $false
      for ($k = $paramObjs.Count - 1; $k -ge 0; $k--) {
        $po = $paramObjs[$k]
        $hasDef = ($po.Default -match '=')
        if ($hasDef) { continue }  # skip and keep checking earlier params

        $tlow = $po.Type.ToLowerInvariant()
        $nlow = $po.Name.ToLowerInvariant()

        $isPrimitive = $primitives -contains $tlow
        if (-not $isPrimitive) {
          $paramObjs[$k]['Default'] = ' = None'; $changedLocal = $true; continue
        }

        if ($tlow -eq 'bool') {
          if ($nlow -match '(display|show|enable|allow|also|available|setavailable|auto)') {
            $paramObjs[$k]['Default'] = ' = True'
          } elseif ($nlow -match '(force|skip|silent|disable|^no|prevent|block)') {
            $paramObjs[$k]['Default'] = ' = False'
          } else {
            $paramObjs[$k]['Default'] = ' = False'
          }
          $changedLocal = $true
          continue
        }

        if ($tlow -eq 'float') {
          $paramObjs[$k]['Default'] = ' = 0.0'; $changedLocal = $true; continue
        }

        if ($tlow -eq 'string') {
          $paramObjs[$k]['Default'] = ' = ""'; $changedLocal = $true; continue
        }

        if ($tlow -eq 'int') {
          # Default trailing Ints; allow leading Int if all to the right already have defaults (except 'stage')
          $allRightHaveDefaults = $true
          for ($r = $k + 1; $r -lt $paramObjs.Count; $r++) {
            if (-not ($paramObjs[$r].Default -match '=')) { $allRightHaveDefaults = $false; break }
          }
          if ($k -gt 0 -or ($k -eq 0 -and $allRightHaveDefaults -and $nlow -ne 'stage')) {
            $paramObjs[$k]['Default'] = ' = 0'; $changedLocal = $true; continue
          }
          break
        }
      }

      if ($changedLocal) {
        # Rebuild params
        $rebuilt = @()
        foreach ($po in $paramObjs) {
          $def = $po.Default; if ($null -eq $def) { $def = '' }
          $rebuilt += ,("{0} {1}{2}" -f $po.Type, $po.Name, $def)
        }
        $newParams = ($rebuilt -join ', ')

        # Splice into original line (literal)
        $open = $orig.IndexOf('(')
        if ($open -lt 0) { continue }
        $close = $orig.IndexOf(')', $open + 1)
        if ($close -lt 0) { continue }

        $left  = $orig.Substring(0, $open + 1)
        $right = $orig.Substring($close)
        $lines[$i] = $left + $newParams + $right
        $changedAny = $true
      }
    }
  }

  if (-not $changedAny) { return $text }
  return ($lines -join $NL)
}


# Infer-FunctionLogicGuards (per-guard cross-function, declared properties only) ---
function Infer-FunctionLogicGuards([string]$text) {
  if (-not $text) { return $text }
  $NL = "`r`n"
  $lf = $text -replace "`r`n?", "`n"
  $lines = $lf -split "`n", 0, 'SimpleMatch'

  function _code([string]$ln) {
    if ($null -eq $ln) { return "" }
    if ($ln -match '^(.*?)(;.*)$') { return $Matches[1] } else { return $ln }
  }

  # Find header region (before first Function/Event)
  $firstBody = $lines.Count
  for ($i=0; $i -lt $lines.Count; $i++) {
    $c = _code $lines[$i]
    if ($c -imatch '^\s*(?:\w[\w\[\]:]*\s+)*Function\b' -or $c -imatch '^\s*Event\b') { $firstBody = $i; break }
  }

  # Header guard declarations
  $headerGuards = @()  # @{ Index; Name; HasPFL }
  for ($i=0; $i -lt $firstBody; $i++) {
    $c = _code $lines[$i]
    if ($c -match '^\s*Guard\s+([A-Za-z0-9_]+)\b(.*)$') {
      $headerGuards += ,@{ Index=$i; Name=$Matches[1]; HasPFL=($Matches[2] -match '\bProtectsFunctionLogic\b') }
    }
  }
  if ($headerGuards.Count -eq 0) { return $text }

  # Declared properties
  $props = New-Object 'System.Collections.Generic.HashSet[string]'
  for ($i=0; $i -lt $lines.Count; $i++) {
    $c = _code $lines[$i]
    if ($c -match '^\s*(?:[A-Za-z0-9_:\[\]]+\s+)?Property\s+([A-Za-z0-9_]+)\b') {
      $null = $props.Add($Matches[1].ToLowerInvariant())
    }
  }
  if ($props.Count -eq 0) { return $text }

  function _hits([string]$codeLine, $set) {
    if (-not $codeLine) { return @() }
    $low = $codeLine.ToLowerInvariant()
    $hits = @()
    foreach ($p in $set) {
      if ($low -match ('(^|[^A-Za-z0-9_])' + [regex]::Escape($p) + '([^A-Za-z0-9_]|$)')) { $hits += ,$p }
    }
    return $hits
  }

  # Build per-guard INSIDE sets and OUTSIDE-any-guard set across all functions/events
  $insideByGuard = @{}  # guard -> HashSet(props)
  $outsideAny    = New-Object 'System.Collections.Generic.HashSet[string]'
  $guardUsed     = New-Object 'System.Collections.Generic.HashSet[string]'

  $inBlock = $false
  $stack = New-Object 'System.Collections.Generic.List[string]'
  $inBlockComment = $false

  for ($i=0; $i -lt $lines.Count; $i++) {
    $ln = $lines[$i]
    if ($ln -match ';/') { $inBlockComment = $true }
    if ($inBlockComment) { if ($ln -match '/;') { $inBlockComment = $false }; continue }
    $c = _code $ln

    if ($c -imatch '^\s*(?:\w[\w\[\]:]*\s+)*Function\b' -or $c -imatch '^\s*Event\b') { $inBlock=$true; $stack.Clear(); continue }
    if ($c -imatch '^\s*EndFunction\b' -or $c -imatch '^\s*EndEvent\b') { $inBlock=$false; $stack.Clear(); continue }
    if (-not $inBlock) { continue }

    if ($c -match '^\s*(TryLockGuard|LockGuard|TryGuard|Guard)\s+([A-Za-z0-9_]+)\b') {
      $g = $Matches[2].ToLowerInvariant()
      $stack.Add($g) | Out-Null
      $null = $guardUsed.Add($g)
      continue
    }
    if ($c -match '^\s*End(TryLockGuard|LockGuard|Guard)\b') {
      if ($stack.Count -gt 0) { $stack.RemoveAt($stack.Count-1) }
      continue
    }

    $hits = _hits $c $props
    if ($hits.Count -gt 0) {
      if ($stack.Count -eq 0) {
        foreach ($h in $hits) { $null = $outsideAny.Add($h) }
      } else {
        foreach ($g in $stack) {
          if (-not $insideByGuard.ContainsKey($g)) { $insideByGuard[$g] = New-Object 'System.Collections.Generic.HashSet[string]' }
          foreach ($h in $hits) { $null = $insideByGuard[$g].Add($h) }
        }
      }
    }
  }

  # Decide per-guard via intersection
  $pfl = New-Object 'System.Collections.Generic.HashSet[string]'
  foreach ($hg in $headerGuards) {
    $gLow = $hg.Name.ToLowerInvariant()
    if (-not $guardUsed.Contains($gLow)) { continue }
    if ($insideByGuard.ContainsKey($gLow)) {
      foreach ($p in $outsideAny) {
        if ($insideByGuard[$gLow].Contains($p)) { $null = $pfl.Add($gLow); break }
      }
    }
  }
  if ($pfl.Count -eq 0) { return $text }

  # 1) Annotate header
  foreach ($hg in $headerGuards) {
    $gLow = $hg.Name.ToLowerInvariant()
    if ($pfl.Contains($gLow) -and -not $hg.HasPFL) {
      $idx = $hg.Index
      $raw = $lines[$idx]
      $semi = $raw.IndexOf(';')
      if ($semi -ge 0) { $codePart = $raw.Substring(0, $semi).TrimEnd(); $comment = $raw.Substring($semi) } else { $codePart = $raw.TrimEnd(); $comment = "" }
      if ($codePart -notmatch '\bProtectsFunctionLogic\b') { $codePart += ' ProtectsFunctionLogic' }
      $lines[$idx] = $codePart + $comment
    }
  }

  # 2) Selectively remove RequiresGuard(G) for properties in the intersection
  $propDecls = @{}  # name -> [indices]
  for ($i=0; $i -lt $lines.Count; $i++) {
    $c = _code $lines[$i]
    if ($c -match '^\s*(?:[A-Za-z0-9_:\[\]]+\s+)?Property\s+([A-Za-z0-9_]+)\b') {
      $pn = $Matches[1].ToLowerInvariant()
      if (-not $propDecls.ContainsKey($pn)) { $propDecls[$pn] = New-Object 'System.Collections.Generic.List[int]' }
      $propDecls[$pn].Add($i) | Out-Null
    }
  }
  foreach ($hg in $headerGuards) {
    $gName = $hg.Name; $gLow = $hg.Name.ToLowerInvariant()
    if (-not $pfl.Contains($gLow)) { continue }
    if (-not $insideByGuard.ContainsKey($gLow)) { continue }
    foreach ($pn in $insideByGuard[$gLow]) {
      if ($propDecls.ContainsKey($pn)) {
        foreach ($li in $propDecls[$pn]) {
          $lines[$li] = ($lines[$li] -replace ('\s*\bRequiresGuard\s*\(\s*' + [regex]::Escape($gName) + '\s*\)'), '')
        }
      }
    }
  }

  ($lines -join "`n") -replace "`n", $NL
}

function Resolve-GuardContractConflicts([string]$text) {
  if (-not $text) { return $text }
  $NL = "`r`n"
  $lf = $text -replace "`r`n?", "`n"
  $lines = $lf -split "`n", 0, 'SimpleMatch'

  function _code([string]$ln) {
    if ($null -eq $ln) { return "" }
    if ($ln -match '^(.*?)(;.*)$') { return $Matches[1] } else { return $ln }
  }

  function _findEndFunction($startIdx) {
    $j = $startIdx + 1; $nest = 0
    while ($j -lt $lines.Count) {
      $cj = _code $lines[$j]
      if ($cj -match '^\s*(?:\w[\w\[\]:]*\s+)*Function\b' -or $cj -match '^\s*Event\b') { $nest++ }
      if ($cj -match '^\s*EndFunction\b' -or $cj -match '^\s*EndEvent\b') {
        if ($nest -eq 0) { return $j } else { $nest-- }
      }
      $j++
    }
    return -1
  }

  function _hasWrapper($fstart, $fend, $guardName) {
    $g = [regex]::Escape($guardName)
    for ($k = $fstart + 1; $k -lt $fend; $k++) {
      $ck = _code $lines[$k]
      if ([regex]::IsMatch($ck, '^\s*(TryLockGuard|LockGuard|Guard)\s+' + $g + '\b', 'IgnoreCase')) { return $true }
    }
    return $false
  }

  # Find functions that declare RequiresGuard(G) and also contain a wrapper with the same G
  for ($i=0; $i -lt $lines.Count; $i++) {
    $c = _code $lines[$i]
    $m = [regex]::Match($c, '^\s*(?:\w[\w\[\]:]*\s+)*Function\s+([A-Za-z0-9_]+)\s*\([^)]*\)\s*RequiresGuard\s*\(\s*([A-Za-z0-9_]+)\s*\)', 'IgnoreCase')
    if ($m.Success) {
      $guard = $m.Groups[2].Value
      $fend = _findEndFunction $i
      if ($fend -lt 0) { continue }
      if (_hasWrapper $i $fend $guard) {
        # Always prefer the callee-held wrapper: remove RequiresGuard from signature
        $sig = $lines[$i]
        $newSig = $sig -replace '\s+RequiresGuard\s*\(\s*[A-Za-z0-9_]+\s*\)', ''
        if ($newSig -ne $sig) {
          $lines[$i] = $newSig + ' ; [removed RequiresGuard(' + $guard + ') due to inline guard wrapper]'
        }
      }
      $i = $fend
    }
  }

  ($lines -join "`n") -replace "`n", $NL
}

function Process-File($inFile) {
  # PSC-only guard
  if ([System.IO.Path]::GetExtension($inFile.FullName) -ne '.psc') {    try { $text = Infer-FunctionLogicGuards $text } catch { throw "Infer-FunctionLogicGuards(start): $($_.Exception.Message)" }
 return
}

  # Read raw and build WorkingBytes via universal Champ header normalization
  $raw = [string]([System.IO.File]::ReadAllText($inFile.FullName, [Text.Encoding]::UTF8))
  $rawBytes = [System.Text.Encoding]::UTF8.GetBytes([string]$raw)
  $champ = Normalize-ChampHeader -Bytes $rawBytes
  $WorkingBytes        = $champ.Bytes
  $HeaderWasNormalized = $champ.Changed
  $WorkingEncoding     = $champ.Encoding

  # Convert to text for downstream editing
  $text = [System.Text.Encoding]::UTF8.GetString($WorkingBytes)
  
  # --- Special-case: DLC001 interactive object sequencer failed decompile ---
  if ($inFile.Name -ieq 'SFBGS001InteractiveObjectSequencer.psc') {
  $NL = "`r`n"
  # Extract ScriptName line if present; otherwise synthesize from basename
  $lf = $text -replace "`r`n?", "`n"
  $origLines = $lf -split "`n", 0, 'SimpleMatch'
  $scriptLine = $null
  $scriptIdx = -1
  for ($ii=0; $ii -lt $origLines.Count; $ii++) {
    if ($origLines[$ii] -match '^\s*ScriptName\b') { $scriptLine = $origLines[$ii]; $scriptIdx = $ii; break }
  }
  if (-not $scriptLine) {
    $base = [System.IO.Path]::GetFileNameWithoutExtension($inFile.Name)
    $scriptLine = "ScriptName $base"
  }

  # Comment out the rest of the original file contents
  $commented = New-Object 'System.Collections.Generic.List[string]'
  $commented.Add("") | Out-Null
  $commented.Add("; --- original decompile commented out due to known broken DLC001 script ---") | Out-Null
  for ($ii=0; $ii -lt $origLines.Count; $ii++) {
    if ($ii -eq $scriptIdx) { continue }
    $line = $origLines[$ii]
    if ([string]::IsNullOrEmpty($line)) {
      $commented.Add(";") | Out-Null
    } else {
      $commented.Add("; " + $line) | Out-Null
    }
  }

  $text = $scriptLine + $NL + ($commented.ToArray() -join $NL) + $NL

  # Write and short-circuit the rest of the pipeline
  $outPath = Get-FixedOutPath $inFile
  $outDir  = Split-Path -Parent $outPath
  if (-not (Test-Path -LiteralPath $outDir)) { [void](New-Item -ItemType Directory -Force -Path $outDir) }
  [System.IO.File]::WriteAllText($outPath, $text, $WorkingEncoding)
  $Script:StatChanged++
  Write-Host ("Processed -> {0}" -f $outPath)
  return
}


  # Detect fragment and, if present, reshape fragment blocks and move properties
  if ($text -match 'Function\s+Fragment') {
try { $text = Transform-FragmentText $text } catch { throw "Transform-FragmentText: $($_.Exception.Message)" }
  }

function Fix-GuardBlocks([string]$text) {

# Strip Champollion experimental guard warning comments (standalone or trailing)
$text = $text -replace '(?m)^[ \t]*;[*]{3}\s*WARNING:\s*(?:Guard declaration syntax is EXPERIMENTAL, subject to change|Experimental syntax, may be incorrect:\s*(?:Guard|TryGuard|EndGuard))\s*\r?\n', ''
$text = $text -replace '(?m)[ \t]*;[*]{3}\s*WARNING:\s*(?:Guard declaration syntax is EXPERIMENTAL, subject to change|Experimental syntax, may be incorrect:\s*(?:Guard|TryGuard|EndGuard))\s*$', ''
try { $text = Fix-GetAllMatchingStructs $text } catch { throw "Fix-GetAllMatchingStructs: $($_.Exception.Message)" }
  if ($null -eq $text) { return $text }
  $NL = "`r`n"
  $lf = $text -replace "`r`n?", "`n"
  $lines = $lf -split "`n", 0, 'SimpleMatch'

  $out = New-Object System.Collections.Generic.List[string]
  $inBlock = $false
  $guardStack = New-Object 'System.Collections.Generic.List[string]'

  foreach ($ln in $lines) {
    $raw  = $ln
    $code = [string](Get-CodePortion $ln)

    # Enter/exit function or event scopes (type-aware: optional type tokens before 'Function')
    if ($code -imatch '^\s*(?:[A-Za-z0-9_\[\]:]+\s+)*Function\b' -or $code -imatch '^\s*Event\b') {
      $inBlock = $true
      $guardStack.Clear()
      $out.Add($raw)
      continue
    }
    if ($code -imatch '^\s*EndFunction\b' -or $code -imatch '^\s*EndEvent\b') {
      $inBlock = $false
      $guardStack.Clear()
      $out.Add($raw)
      continue
    }

    if ($inBlock) {
      # Normalize openings
      if ($code -imatch '^\s*TryGuard\s+([A-Za-z0-9_]+)') {
        $indent = ([regex]::Match($ln, '^\s*')).Value
        $name   = $Matches[1]
        $comment = ""
        if ($ln -match ';.*$') { $comment = ([string]$ln).Substring(([string]$ln).IndexOf(';')) }
        $guardStack.Add('TryLockGuard')
        $out.Add($indent + 'TryLockGuard ' + $name + $comment)
        continue
      }
      if ($code -imatch '^\s*Guard\s+([A-Za-z0-9_]+)') {
        $indent = ([regex]::Match($ln, '^\s*')).Value
        $name   = $Matches[1]
        $comment = ""
        if ($ln -match ';.*$') { $comment = ([string]$ln).Substring(([string]$ln).IndexOf(';')) }
        $guardStack.Add('LockGuard')
        $out.Add($indent + 'LockGuard ' + $name + $comment)
        continue
      }
      if ($code -imatch '^\s*TryLockGuard\s+([A-Za-z0-9_]+)') {
        $guardStack.Add('TryLockGuard')
        $out.Add($raw)
        continue
      }
      if ($code -imatch '^\s*LockGuard\s+([A-Za-z0-9_]+)') {
        $guardStack.Add('LockGuard')
        $out.Add($raw)
        continue
      }

      # Normalize closing
      if ($code -imatch '^\s*EndGuard\b') {
        $indent = ([regex]::Match($ln, '^\s*')).Value
        $comment = ""
        if ($ln -match ';.*$') { $comment = ([string]$ln).Substring(([string]$ln).IndexOf(';')) }
        $kind = $null
        if ($guardStack.Count -gt 0) {
          $kind = $guardStack[$guardStack.Count-1]
          $guardStack.RemoveAt($guardStack.Count-1)
        }
        if ($kind -eq 'TryLockGuard') {
          $out.Add($indent + 'EndTryLockGuard' + $comment)
        } else {
          $out.Add($indent + 'EndLockGuard' + $comment)
        }
        continue
      }

      if ($code -imatch '^\s*EndTryLockGuard\b') {
        if ($guardStack.Count -gt 0 -and $guardStack[$guardStack.Count-1] -eq 'TryLockGuard') {
          $guardStack.RemoveAt($guardStack.Count-1)
        }
        $out.Add($raw); continue
      }
      if ($code -imatch '^\s*EndLockGuard\b') {
        if ($guardStack.Count -gt 0 -and $guardStack[$guardStack.Count-1] -eq 'LockGuard') {
          $guardStack.RemoveAt($guardStack.Count-1)
        }
        $out.Add($raw); continue
      }

      $out.Add($raw)
    } else {
      # Top-level: preserve one-line Guard declarations; revert accidental top-level LockGuard to Guard.
      if ($code -imatch '^\s*LockGuard\s+([A-Za-z0-9_]+)') {
        $indent = ([regex]::Match($ln, '^\s*')).Value
        $name   = $Matches[1]
        $comment = ""
        if ($ln -match ';.*$') { $comment = ([string]$ln).Substring(([string]$ln).IndexOf(';')) }
        $out.Add($indent + 'Guard ' + $name + ($(if ($code -match 'ProtectsFunctionLogic') { ' ProtectsFunctionLogic' } else { '' })) + $comment)
        continue
      }
      $out.Add($raw)
    }
  }

  $tmp = (($out -join "`n") -replace "`n", $NL)
try { $tmp = Strip-RequiresGuardWhenGuardIsPFL $tmp } catch { throw "Strip-RequiresGuardWhenGuardIsPFL: $($_.Exception.Message)" }
$tmp
}



function Fix-RemoteEventCastsFromLocalDecls([string]$text) {
  if ($null -eq $text) { return $text }
  $NL = "`r`n"
  $lf = $text -replace "`r`n?", "`n"
  $lines = $lf -split "`n", 0, 'SimpleMatch'

  function _code([string]$ln) {
    if ($null -eq $ln) { return "" }
    if ($ln -match '^(.*?)(;.*)$') { return $Matches[1] } else { return $ln }
  }

  # ---- Build global type map from Properties (both orders) + top-level fields
  #      SKIPPING anything inside { ... } comment regions. ----
  $globalTypes = New-Object 'System.Collections.Generic.Dictionary[string,string]'
  $inBlock = $false
  $curlyDepth = 0
  for ($i=0; $i -lt $lines.Count; $i++) {
    $raw = $lines[$i]
    $c   = _code $raw

    # Track curly-brace comment regions
    $opens  = ([regex]::Matches($raw, '\{')).Count
    $closes = ([regex]::Matches($raw, '\}')).Count
    $curlyActive = ($curlyDepth -gt 0)

    # Track code blocks so we only treat true top-level fields
    if ($c -imatch '^\s*(?:[A-Za-z0-9_:\[\]]+\s+)*Function\b' -or $c -imatch '^\s*Event\b' -or $c -imatch '^\s*State\b') { $inBlock = $true }
    if ($c -imatch '^\s*EndFunction\b' -or $c -imatch '^\s*EndEvent\b' -or $c -imatch '^\s*EndState\b')               { $inBlock = $false }

    # Only parse declarations when NOT inside { ... } comments, and line itself isn’t a brace line
    if (-not $curlyActive -and $opens -eq 0 -and $closes -eq 0) {
      # Properties (both orders)
      if     ($c -match '^\s*([A-Za-z0-9_:\[\]]+)\s+Property\s+([A-Za-z_][A-Za-z0-9_]*)\b') { $globalTypes[$Matches[2]] = $Matches[1] }
      elseif ($c -match '^\s*Property\s+([A-Za-z_][A-Za-z0-9_]*)\s+([A-Za-z0-9_:\[\]]+)\b') { $globalTypes[$Matches[1]] = $Matches[2] }
      # Top-level fields “Type Name” (exclude keywords; also skip obvious prose lines with apostrophes)
      elseif (-not $inBlock -and $c -notmatch "[']" -and
             $c -match '^\s*(?!ScriptName\b)(?!Import\b)(?!Guard\b)(?!Group\b)(?!EndGroup\b)(?!State\b)(?!Event\b)(?!Function\b)([A-Za-z0-9_:\[\]]+)\s+([A-Za-z_][A-Za-z0-9_]*)\b') {
        $globalTypes[$Matches[2]] = $Matches[1]
      }
    }

    # Update curly depth at END of line so single-line "{ … }" is treated as comment, too
    $curlyDepth = [Math]::Max(0, $curlyDepth + $opens - $closes)
  }

  $out = New-Object 'System.Collections.Generic.List[string]'
  $inBlock = $false
  $scopeTypes = $null

  for ($i=0; $i -lt $lines.Count; $i++) {
    $raw = $lines[$i]
    $c   = _code $raw

    # Enter/exit blocks; seed scope with globals
    if ($c -imatch '^\s*(?:[A-Za-z0-9_:\[\]]+\s+)*Function\b') {
      $inBlock = $true
      $scopeTypes = New-Object 'System.Collections.Generic.Dictionary[string,string]'
      foreach ($k in $globalTypes.Keys) { $scopeTypes[$k] = $globalTypes[$k] }
      if ($c -match '^\s*(?:[A-Za-z0-9_:\[\]]+\s+)*Function\s+[A-Za-z_]\w*\s*\((.*?)\)') {
        foreach ($pm in [regex]::Matches($Matches[1], '([A-Za-z0-9_:\[\]]+)\s+([A-Za-z_][A-Za-z0-9_]*)')) {
          if ($pm.Groups[1].Value -notmatch '\[') { $scopeTypes[$pm.Groups[2].Value] = $pm.Groups[1].Value }
        }
      }
      $out.Add($raw); continue
    }
    if ($c -imatch '^\s*EndFunction\b') { $inBlock=$false; $scopeTypes=$null; $out.Add($raw); continue }

    if ($c -imatch '^\s*Event\b') {
      $inBlock = $true
      $scopeTypes = New-Object 'System.Collections.Generic.Dictionary[string,string]'
      foreach ($k in $globalTypes.Keys) { $scopeTypes[$k] = $globalTypes[$k] }
      if ($c -match '^\s*Event\s+[A-Za-z0-9_]+\.[A-Za-z0-9_]+\s*\((.*?)\)') {
        foreach ($pm in [regex]::Matches($Matches[1], '([A-Za-z0-9_:\[\]]+)\s+([A-Za-z_][A-Za-z0-9_]*)')) {
          if ($pm.Groups[1].Value -notmatch '\[') { $scopeTypes[$pm.Groups[2].Value] = $pm.Groups[1].Value }
        }
      }
      $out.Add($raw); continue
    }
    if ($c -imatch '^\s*EndEvent\b') { $inBlock=$false; $scopeTypes=$null; $out.Add($raw); continue }

    if ($c -imatch '^\s*State\b')    { $inBlock=$true;  $scopeTypes = New-Object 'System.Collections.Generic.Dictionary[string,string]'; foreach ($k in $globalTypes.Keys) { $scopeTypes[$k]=$globalTypes[$k] }; $out.Add($raw); continue }
    if ($c -imatch '^\s*EndState\b') { $inBlock=$false; $scopeTypes=$null; $out.Add($raw); continue }

    if ($inBlock) {
      # Local decls: “Type Name = …” (avoid control keywords; single ‘=’)
      if ($c -match '^\s*(?!If\b)(?!ElseIf\b)(?!While\b)(?!Until\b)(?!Return\b)([A-Za-z0-9_:\[\]]+)\s+([A-Za-z_][A-Za-z0-9_]*)\s*=(?!=)') {
        if ($Matches[1] -notmatch '\[') { $scopeTypes[$Matches[2]] = $Matches[1] }
      }

      # Rewrites for simple identifiers only
      if ($c -match '(^|\s)(?:Self\.)?((?:Register|Unregister)For(?:RemoteEvent|ActorValueChangedEvent|CustomEvent))\s*\(\s*([A-Za-z_][A-Za-z0-9_]*)\s*(?:as\s+([A-Za-z0-9_]+))?(\s*,[^)]*\))') {
        $prefix = $Matches[1]; $call = $Matches[2]; $id = $Matches[3]; $cast = $Matches[4]; $suffix = $Matches[5]
        $want = $null; if ($scopeTypes -and $scopeTypes.ContainsKey($id)) { $want = $scopeTypes[$id] }
        if ($want -and (-not $cast -or $cast -ne $want -or $cast -match '^(?i:ScriptObject|ObjectReference)$')) {
          $semi    = $raw.IndexOf(';')
          $comment = if ($semi -ge 0) { $raw.Substring($semi) } else { "" }
          $newcode = $prefix + $call + '(' + $id + ' as ' + $want + $suffix
          $out.Add($newcode + $comment); continue
        }
      }
    }

    $out.Add($raw)
  }

  ($out -join "`n") -replace "`n", $NL
}



function Fix-RedundantOuterAliasCast([string]$text) {
  if ($null -eq $text) { return $text }
  $NL = "`r`n"
  $lf = $text -replace "`r`n?", "`n"
  $lines = $lf -split "`n", 0, 'SimpleMatch'
  $out = New-Object System.Collections.Generic.List[string]

  foreach ($ln in $lines) {
    $raw = $ln
    # Pattern: RegisterForRemoteEvent((... as ReferenceAlias)) as RefCollectionAlias, "Event")
    $m = [regex]::Match($ln, '(?i)^\s*((?:Self\.)?(?:Register|Unregister)ForRemoteEvent\()\s*\((?<inner>[^)]*?\bas\s+(ReferenceAlias|RefCollectionAlias)\b[^)]*)\)\s+as\s+(ReferenceAlias|RefCollectionAlias|ScriptObject)\s*(?<tail>,\s*"[A-Za-z0-9_:]+"\s*\).*)$')
    if ($m.Success) {
      $inner = $m.Groups['inner'].Value
      $ln = $m.Groups[1].Value + '(' + $inner + ')' + $m.Groups['tail'].Value
      $out.Add($ln); continue
    }
    $out.Add($raw)
  }

  $joined = ($out -join "`n") -replace "`n", $NL
  return ($joined.TrimEnd() + $NL)
}

function Fix-EventSelfSenderCast([string]$text) {
  if ($null -eq $text) { return $text }
  $NL = "`r`n"
  $lf = $text -replace "`r`n?", "`n"
  $lines = $lf -split "`n", 0, 'SimpleMatch'

  $out = New-Object System.Collections.Generic.List[string]
  $inEvent = $false
  $eventSenderType = $null
  $eventSenderName = $null

  foreach ($ln in $lines) {
    $raw = $ln
    if (-not $inEvent) {
      # Enter a typed event: Event <Type>.<Name>(<Type> <sender>, ...)
      $m = [regex]::Match($ln, '(?i)^\s*Event\s+([A-Za-z0-9_:]+)\s*\.\s*([A-Za-z0-9_]+)\s*\(\s*([A-Za-z0-9_:]+)\s+([A-Za-z_][A-Za-z0-9_]*)')
      if ($m.Success) {
        $inEvent = $true
        $eventSenderType = $m.Groups[1].Value
        $eventSenderName = $m.Groups[4].Value
        $out.Add($raw); continue
      }
      $out.Add($raw); continue
    } else {
      # Inside event
      if ($ln -match '^\s*EndEvent\b') {
        $inEvent = $false
        $eventSenderType = $null
        $eventSenderName = $null
        $out.Add($raw); continue
      }

      if ($eventSenderName -and $eventSenderType) {
        # Rewrite casts for (Un)RegisterForRemoteEvent( <senderName> [as X], "...")
        $re1 = [regex]('(?i)^\s*((?:Self\.)?(?:Register|Unregister)ForRemoteEvent\()\s*(' + [regex]::Escape($eventSenderName) + ')\s+as\s+[A-Za-z0-9_:]+\s*(,\s*"[A-Za-z0-9_:]+"\s*\).*)$')
        if ($re1.IsMatch($ln)) {
          $ln = $re1.Replace($ln, ('$1' + $eventSenderName + ' as ' + $eventSenderType + '$3'))
          $out.Add($ln); continue
        }
        $re2 = [regex]('(?i)^\s*((?:Self\.)?(?:Register|Unregister)ForRemoteEvent\()\s*(' + [regex]::Escape($eventSenderName) + ')(\s*,\s*"[A-Za-z0-9_:]+"\s*\).*)$')
        if ($re2.IsMatch($ln)) {
          $ln = $re2.Replace($ln, ('$1' + $eventSenderName + ' as ' + $eventSenderType + '$3'))
          $out.Add($ln); continue
        }
      }
      $out.Add($raw); continue
    }
  }

  $joined = ($out -join "`n") -replace "`n", $NL
  return ($joined.TrimEnd() + $NL)
}
function Fix-PropertyRequiresGuard([string]$text) {
  if ($null -eq $text) { return $text }
  $NL = "`r`n"
  $lf = $text -replace "`r`n?", "`n"
  $lines = $lf -split "`n", 0, 'SimpleMatch'
  # Types we never promote to RequiresGuard on properties
  $aliasTypes = @('referencealias','refcollectionalias')
  $primitiveTypes = @('int','bool','float','string')
  # Collect all property names with robust type support (arrays/namespaced)
  $allPropNames = New-Object 'System.Collections.Generic.HashSet[string]'
  foreach ($mprop in ([regex]'(?im)^\s*(?:[A-Za-z0-9_:\[\]]+\s+)?Property\s+([A-Za-z0-9_]+)\b').Matches($lf)) {
    [void]$allPropNames.Add($mprop.Groups[1].Value.ToLowerInvariant())
  }
  # 1) Collect top-level Guard names (canonical casing)
  $topGuards = @{}  # lower -> original
  $inBlock = $false
  foreach ($ln in $lines) {
    $code = [string](Get-CodePortion $ln)
    if ($code -imatch '^\s*(?:[A-Za-z0-9_\[\]:]+\s+)*Function\b' -or $code -imatch '^\s*Event\b') { $inBlock = $true; continue }
    if ($code -imatch '^\s*EndFunction\b' -or $code -imatch '^\s*EndEvent\b') { $inBlock = $false; continue }
    if (-not $inBlock) {
      if ($null -ne $Matches) { try { $Matches.Clear() } catch {} }
      if ($code -imatch '^\s*(?:LockGuard|Guard)\s+([A-Za-z0-9_]+)') {
        $name = $Matches[1]
        if (-not [string]::IsNullOrEmpty($name)) {
          $low = ([string]$name).ToLowerInvariant()
          if (-not $topGuards.ContainsKey($low)) { $topGuards[$low] = $name }
        }
      }
    }
  }

  # 2) Index property declarations (track const-ness and declaration index)
  $propIdx = @{}         # lower -> index
  $propHasReq = @{}      # lower -> bool
  $propIsConst = @{}     # lower -> bool
  for ($i=0; $i -lt $lines.Count; $i++) {
    $code = [string](Get-CodePortion $lines[$i])
    if ($code -imatch '^\s*[A-Za-z0-9_\[\]:]+\s+Property\s+([A-Za-z0-9_]+)\b' -or $code -imatch '^\s*Property\s+([A-Za-z0-9_]+)\b') {
      $name = $Matches[1]
      if (-not [string]::IsNullOrEmpty($name)) {
        $low = ([string]$name).ToLowerInvariant()
        if (-not $propIdx.ContainsKey($low)) { $propIdx[$low] = $i }
        $propHasReq[$low] = ($code -imatch '\bRequiresGuard\s*\(')
        $propIsConst[$low] = ($code -imatch '\bConst\b')
      }
    }
  }
  if ($propIdx.Count -eq 0 -or $topGuards.Count -eq 0) { return $text }

  # 3) Scan uses; track guards, unguarded uses, and mutations
  $needReq = @{}                   # propLow -> chosen guard (single)
  $propGuardList = @{}             # propLow -> List[string] of guard names seen
  $propUnguarded = @{}             # propLow -> $true if any unguarded use (read or write)
  $propMutGuarded = @{}            # propLow -> $true if any mutating use under a guard
  $propMutUnguarded = @{}          # propLow -> $true if any mutating use unguarded

  $guardStack = New-Object 'System.Collections.Generic.List[string]'

  $blockStack = New-Object 'System.Collections.Generic.List[object]'       # stack of @{ GuardLow; Props }
  $guardBlocks = New-Object 'System.Collections.Generic.Dictionary[string,System.Collections.Generic.List[System.Collections.Generic.HashSet[string]]]' # guardLow -> list of prop sets per block  $inBlock = $false

  function _IsMutating([string]$codeLower, [string]$pLow) {
    $esc = [regex]::Escape($pLow)
    $assignPat      = "(?i)(^|[^A-Za-z0-9_])" + $esc + "\s*="
    $indexAssignPat = "(?i)(^|[^A-Za-z0-9_])" + $esc + "\s*\[.+?\]\s*="
    $augAssignPat   = "(?i)(^|[^A-Za-z0-9_])" + $esc + "\s*(\+|\-|\*|/|%)="
    $mutMethodPat   = "(?i)(^|[^A-Za-z0-9_])" + $esc + "\s*\.\s*(remove|removeat|add|insert|append|push|pop|clear)\b"
    if ($codeLower -match $assignPat)      { return $true }
    if ($codeLower -match $indexAssignPat) { return $true }
    if ($codeLower -match $augAssignPat)   { return $true }
    if ($codeLower -match $mutMethodPat)   { return $true }
    return $false
  }

  for ($i=0; $i -lt $lines.Count; $i++) {
    $ln = $lines[$i]
    $code = [string](Get-CodePortion $ln)

    if ($code -imatch '^\s*(?:[A-Za-z0-9_\[\]:]+\s+)*Function\b' -or $code -imatch '^\s*Event\b') { $inBlock = $true; $guardStack.Clear(); continue }
    if ($code -imatch '^\s*EndFunction\b' -or $code -imatch '^\s*EndEvent\b')  { $inBlock = $false; $guardStack.Clear(); continue }

    if ($inBlock) {
      if ($null -ne $Matches) { try { $Matches.Clear() } catch {} }
      if ($code -imatch '^\s*(TryLockGuard|LockGuard|TryGuard|Guard)\s+([A-Za-z0-9_]+)') {
        $guardStack.Add($Matches[2]); continue
      }
      if ($code -imatch '^\s*End(TryLockGuard|LockGuard|Guard)\b') {
        if ($guardStack.Count -gt 0) { $guardStack.RemoveAt($guardStack.Count-1) }
        continue
      }

      if ($propIdx.Count -gt 0) {
        $codeLower = ([string]$code).ToLowerInvariant()
        foreach ($kv in $propIdx.GetEnumerator()) {
          $pLow = $kv.Key
          $pat = '(^|[^A-Za-z0-9_])' + [regex]::Escape($pLow) + '([^A-Za-z0-9_]|$)'
          if ($codeLower -match $pat) {
            $isMut = _IsMutating $codeLower $pLow
            if ($blockStack.Count -gt 0) {
              $blockStack[$blockStack.Count-1].Props.Add($pLow) | Out-Null
            }
            if ($guardStack.Count -gt 0) {
              $active = $guardStack[$guardStack.Count-1]
              $gLow = ([string]$active).ToLowerInvariant()
              if ($topGuards.ContainsKey($gLow)) { $gName = $topGuards[$gLow] } else { $gName = $active }
              if (-not $propGuardList.ContainsKey($pLow)) {
                $propGuardList[$pLow] = New-Object 'System.Collections.Generic.List[string]'
              }
              if (-not $propGuardList[$pLow].Contains($gName)) {
                [void]$propGuardList[$pLow].Add($gName)
              }
              if ($isMut) { $propMutGuarded[$pLow] = $true }
            } else {
              $propUnguarded[$pLow] = $true
              if ($isMut) { $propMutUnguarded[$pLow] = $true }
            }
          }
        }
      }
    }
  }

  # 4) Decide which properties to annotate: only non-Const, mutated, single-guard, and never mutated unguarded
  foreach ($kv in $propIdx.GetEnumerator()) {
    $pLow = $kv.Key
    if ($propHasReq.ContainsKey($pLow) -and $propHasReq[$pLow]) { continue }
    if ($propIsConst.ContainsKey($pLow) -and $propIsConst[$pLow]) { continue }

    $guards = $null
    if ($propGuardList.ContainsKey($pLow)) { $guards = $propGuardList[$pLow] }

    $singleGuard = ($guards -ne $null -and $guards.Count -eq 1)
    $anyUnguardedUse = ($propUnguarded.ContainsKey($pLow) -and $propUnguarded[$pLow])
    $hasMutGuarded   = ($propMutGuarded.ContainsKey($pLow) -and $propMutGuarded[$pLow])
    $hasMutUnguarded = ($propMutUnguarded.ContainsKey($pLow) -and $propMutUnguarded[$pLow])

    # Ensure guard's lock blocks all reference this property at least once
    $guardName = $null
    if ($singleGuard) { $guardName = $guards[0] }
    $okAllBlocks = $true
    if ($guardName) {
      $gLowCheck = ([string]$guardName).ToLowerInvariant()
      if ($guardBlocks.ContainsKey($gLowCheck)) {
        foreach ($blkProps in $guardBlocks[$gLowCheck]) {
          if (-not $blkProps.Contains($pLow)) { $okAllBlocks = $false; break }
        }
      }
    }
    if ($singleGuard -and -not $anyUnguardedUse -and $hasMutGuarded -and -not $hasMutUnguarded -and $okAllBlocks) {
      $guardName = $guards[0]
      $declIdx = $propIdx[$pLow]
      if ($declIdx -ge 0 -and $declIdx -lt $lines.Count) {
        $line = $lines[$declIdx]
        $semi = ([string]$line).IndexOf(';')
        if ($semi -ge 0) {
          $codePart = ([string]$line).Substring(0, $semi).TrimEnd()
          $comment  = ([string]$line).Substring($semi)
          $lines[$declIdx] = $codePart + ' RequiresGuard(' + $guardName + ') ' + $comment
        } else {
          $lines[$declIdx] = ([string]$line).TrimEnd() + ' RequiresGuard(' + $guardName + ')'
        }
      }
    }
  }

  ($lines -join "`n") -replace "`n", $NL
}




function Fix-FunctionRequiresGuard {
  param([string]$text)
  if ($null -eq $text) { return $text }
  $NL = "`r`n"
  $lf = $text -replace "`r`n?", "`n"
  $lines = $lf -split "`n", 0, 'SimpleMatch'

  # Map property -> required guard from declarations
  $propToGuard = @{}
  foreach ($m in ([regex]'(?im)^\s*(?:[A-Za-z0-9_:\[\]]+\s+)?Property\s+([A-Za-z0-9_]+)\b.*?\bRequiresGuard\(\s*([A-Za-z0-9_]+)\s*\)').Matches($lf)) {
    $p = $m.Groups[1].Value
    $g = $m.Groups[2].Value
    $propToGuard[$p.ToLowerInvariant()] = $g
  }
  if ($propToGuard.Count -eq 0) { return $text }

  $out = $lines.Clone()
  $inFunc = $false; $funcStart = -1; $funcName = ""; $hasReq = $false; $locks = New-Object 'System.Collections.Generic.HashSet[string]'; $refs = New-Object 'System.Collections.Generic.HashSet[string]'
  for ($i=0; $i -lt $lines.Count; $i++) {
    $code = [string](Get-CodePortion $lines[$i])
    if (-not $inFunc) {
      if ($code -imatch '^\s*(?:[A-Za-z0-9_:\[\]]+\s+)?Function\s+([A-Za-z0-9_]+)\s*\(') {
        $inFunc = $true; $funcStart = $i; $funcName = $Matches[1]; $hasReq = ($code -match '(?i)\bRequiresGuard\(')
        $locks.Clear(); $refs.Clear()
      }
      continue
    } else {
      if ($code -imatch '^\s*EndFunction\b') {
        # Decide on RequiresGuard if needed
        if (-not $hasReq) {
          # Compute required guards from property refs
          $needed = New-Object 'System.Collections.Generic.HashSet[string]'
          foreach ($plow in $refs) {
            if ($propToGuard.ContainsKey($plow)) {
              [void]$needed.Add($propToGuard[$plow].ToLowerInvariant())
            }
          }
          foreach ($g in $needed) {
            if (-not $locks.Contains($g)) {
              # add RequiresGuard(g) to function signature line
              $line = $out[$funcStart]
              if ($line -notmatch '(?i)\bRequiresGuard\(') {
                $semi = $line.IndexOf(';')
                if ($semi -ge 0) { $codePart = $line.Substring(0,$semi); $comment = $line.Substring($semi) } else { $codePart = $line; $comment = "" }
                $out[$funcStart] = ($codePart.TrimEnd() + ' RequiresGuard(' + $g + ') ' + $comment).TrimEnd()
              }
            }
          }
        }
        $inFunc = $false
        continue
      }
      # Track internal locks for guards
      if ($code -imatch '^\s*(?:TryLockGuard|LockGuard|Guard)\s+([A-Za-z0-9_]+)\b') {
        [void]$locks.Add($Matches[1].ToLowerInvariant())
      }
      # Track property references
      $low = $code.ToLowerInvariant()
      foreach ($kv in $propToGuard.Keys) {
        if ($low -match ('(^|[^A-Za-z0-9_])' + [regex]::Escape($kv) + '([^A-Za-z0-9_]|$)')) {
          [void]$refs.Add($kv)
        }
      }
    }
  }

  return (($out -join "`n") -replace "`n", $NL)
}





  # Run common fixes for BOTH fragment and non-fragment
try { $text = PreInfer-EventSenderTypes -Text $text } catch { throw "PreInfer-EventSenderTypes: $($_.Exception.Message)" }
try { $text = Fix-EventRegistrations $text } catch { throw "Fix-EventRegistrations: $($_.Exception.Message)" }
try { $text = Fix-EventSenderTypeConsistency $text } catch { throw "Fix-EventSenderTypeConsistency: $($_.Exception.Message)" }
try { $text = Fix-RemoteEventCasts $text } catch { throw "Fix-RemoteEventCasts: $($_.Exception.Message)" }
try { $text = Promote-ActorCasts $text } catch { throw "Promote-ActorCasts: $($_.Exception.Message)" }
try { $text = Promote-ActorCastsInDistanceRegs $text } catch { throw "Promote-ActorCastsInDistanceRegs: $($_.Exception.Message)" }
try { $text = Ensure-CustomEventDecls $text } catch { throw "Ensure-CustomEventDecls: $($_.Exception.Message)" }
try { $text = Ensure-BalancedIfs $text } catch { throw "Ensure-BalancedIfs: $($_.Exception.Message)" }
try { $text = Ensure-BlockClosures $text } catch { throw "Ensure-BlockClosures: $($_.Exception.Message)" }



  # Compare to original normalized text to decide unchanged vs changed
try { $text = Fix-GuardBlocks $text } catch { throw "Fix-GuardBlocks(early): $($_.Exception.Message)" }
try { $text = Fix-PropertyRequiresGuard $text } catch { throw "Fix-PropertyRequiresGuard(early): $($_.Exception.Message)" }

try { $text = Fix-FunctionRequiresGuard $text } catch { throw "Fix-FunctionRequiresGuard: $($_.Exception.Message)" }

try { $text = Comment-UnusedHeaderGuards $text } catch { throw "Comment-UnusedHeaderGuards: $($_.Exception.Message)" }
try { $text = Prune-EmptyGuardBlocks $text } catch { throw "Prune-EmptyGuardBlocks(early): $($_.Exception.Message)" }
  $origNorm = $raw -replace "`r`n?", "`n"
  $origLines = $origNorm -split "`n", 0, 'SimpleMatch'
  $origLines = Remove-ChampollionBanner $origLines
  $origNormalized = ($origLines -join "`n") -replace "`n","`r`n"
  $origNormalized = ([string]$origNormalized).TrimEnd() + "`r`n"

  if ($origNormalized -ceq $text) {
    # Unchanged -> write WorkingBytes (fresh timestamps); count header-only as Changed
    $outPath = Get-FixedOutPath $inFile
    $outDir  = Split-Path -Parent $outPath
    if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
    [System.IO.File]::WriteAllBytes($outPath, $WorkingBytes)
    if ($HeaderWasNormalized) {
      $Script:StatChanged++
      Write-Host ("Processed -> {0}" -f $outPath)
    } else {
      $Script:StatCopied++
      Write-Host ("Processed -> {0}" -f $outPath)
    }
    return
  }

# Default-on pass: comment overrides that call Parent. and are missing bool defaults
try { $text = Fix-GuardBlocks $text } catch { throw "Fix-GuardBlocks(late): $($_.Exception.Message)" }
try { $text = Fix-PropertyRequiresGuard $text } catch { throw "Fix-PropertyRequiresGuard(late): $($_.Exception.Message)" }
try { $text = Ensure-FunctionRequiresGuardByInference $text } catch { throw "Ensure-FunctionRequiresGuardByInference: $($_.Exception.Message)" }
try { $text = Fix-SelfQualifiedLocalFunctionCalls $text } catch { throw "Fix-SelfQualifiedLocalFunctionCalls: $($_.Exception.Message)" }
try { $text = Fix-RemoteEventScriptObjectCast $text } catch { throw "Fix-RemoteEventScriptObjectCast: $($_.Exception.Message)" }
try { $text = Restore-TrailingDefaultArgs $text } catch { throw "Restore-TrailingDefaultArgs: $($_.Exception.Message)" }
try { $text = Ensure-FunctionRequiresGuard $text } catch { throw "Ensure-FunctionRequiresGuard: $($_.Exception.Message)" }
try { $text = Add-ProtectsFunctionLogicForLogicGuards $text } catch { throw "Add-ProtectsFunctionLogicForLogicGuards(late): $($_.Exception.Message)" }
try { $text = Resolve-GuardContractConflicts $text } catch { throw "Resolve-GuardContractConflicts: $($_.Exception.Message)" }
try { $text = Comment-UnusedHeaderGuards $text } catch { throw "Comment-UnusedHeaderGuards: $($_.Exception.Message)" }
try { $text = Prune-EmptyGuardBlocks $text } catch { throw "Prune-EmptyGuardBlocks(late): $($_.Exception.Message)" }


  # Changed -> write text
  $outPath = Get-FixedOutPath $inFile
  if ((Test-Path -LiteralPath $outPath) -and -not $Force) {
    Write-Host "Exists (use -Force to overwrite): $outPath"
    return
  }
  $outDir  = Split-Path -Parent $outPath
  if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
  
try { $text = Fix-RemoteEventCastsFromLocalDecls $text } catch { throw "Fix-RemoteEventCastsFromLocalDecls: $($_.Exception.Message)" }

try { $text = Fix-RedundantOuterAliasCast $text } catch { throw "Fix-RedundantOuterAliasCast: $($_.Exception.Message)" }

try { $text = Fix-EventSelfSenderCast $text } catch { throw "Fix-EventSelfSenderCast: $($_.Exception.Message)" }
[System.IO.File]::WriteAllText($outPath, $text, $WorkingEncoding)
  $Script:StatChanged++
  Write-Host ("Processed -> {0}" -f $outPath)
}


# Run
$files = Get-PscFiles $Path
Write-Host ("Found {0} .psc files under: {1}" -f $files.Count, $Path) -ForegroundColor DarkGray
if (-not $files -or $files.Count -eq 0) { Write-Host "No .psc files found under: $Path"; exit 0 }

foreach ($f in $files) {
  # Skip native base PSCs that are known-bad when decompiled by Champollion
  try {
    $fn = [System.IO.Path]::GetFileName($f)
    if ($SkipFiles -and ($SkipFiles -contains $fn)) {
      $skipped += 1
      Write-Host ("Skipped: {0}" -f $fn) -ForegroundColor Yellow
      continue
    }
  } catch { }

  try { Process-File $f }
  catch { $Script:StatFailed++; Write-Warning ("Failed: {0} -- {1}" -f $f.FullName, $_.Exception.Message) }
}
$changed   = $Script:StatChanged
$copied    = $Script:StatCopied
$failed    = $Script:StatFailed

# Consolidated bucket
$processed = $changed + $copied

Write-Host ("Skipped: {0}" -f $skipped) -ForegroundColor Yellow
Write-Host ("Summary: Processed: {0} | Changed: {1} | Copied: {2} | Failed: {3}" -f $processed, $changed, $copied, $failed) -ForegroundColor Cyan