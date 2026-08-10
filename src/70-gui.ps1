# ============================================================================ #
#  Assistant graphique
#
#  Etape 1 : dossier du jeu (auto-detecte). L'installeur y lit aussi s'il
#            existe deja une installation, et enchaine sur l'etape Action.
#  Etape 2 : Action (uniquement si une installation est detectee)
#  Etape 3 : Mods
#  Etape 4 : Options des mods retenus
#  Etape 5 : Resume
#  Etape 6 : Progression, puis Terminer
# ============================================================================ #

function Show-SetupWizard {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $W = 720; $H = 560
    $BodyTop = 74
    $BodyHeight = $H - $BodyTop - 108

    # ---------------------------------------------------------------- fenetre #
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "me3 - Elden Ring  ($($script:SetupVersion))"
    $form.ClientSize = New-Object System.Drawing.Size($W, $H)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

    # bandeau de titre
    $header = New-Object System.Windows.Forms.Panel
    $header.Location = New-Object System.Drawing.Point(0, 0)
    $header.Size = New-Object System.Drawing.Size($W, ($BodyTop - 12))
    $header.BackColor = [System.Drawing.Color]::White
    $lblTitle = New-Object System.Windows.Forms.Label
    $lblTitle.Location = New-Object System.Drawing.Point(18, 12)
    $lblTitle.Size = New-Object System.Drawing.Size(($W - 36), 22)
    $lblTitle.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
    $lblSub = New-Object System.Windows.Forms.Label
    $lblSub.Location = New-Object System.Drawing.Point(18, 36)
    $lblSub.Size = New-Object System.Drawing.Size(($W - 36), 20)
    $lblSub.ForeColor = [System.Drawing.Color]::DimGray
    $header.Controls.AddRange(@($lblTitle, $lblSub))

    $sep = New-Object System.Windows.Forms.Label
    $sep.Location = New-Object System.Drawing.Point(0, ($BodyTop - 12))
    $sep.Size = New-Object System.Drawing.Size($W, 1)
    $sep.BorderStyle = 'Fixed3D'

    # zone des pages
    $body = New-Object System.Windows.Forms.Panel
    $body.Location = New-Object System.Drawing.Point(0, $BodyTop)
    $body.Size = New-Object System.Drawing.Size($W, $BodyHeight)

    # boutons
    $btnBack = New-Object System.Windows.Forms.Button
    $btnBack.Text = '< Precedent'
    $btnBack.Size = New-Object System.Drawing.Size(110, 30)
    $btnBack.Location = New-Object System.Drawing.Point(($W - 360), ($H - 48))

    $btnNext = New-Object System.Windows.Forms.Button
    $btnNext.Text = 'Suivant >'
    $btnNext.Size = New-Object System.Drawing.Size(110, 30)
    $btnNext.Location = New-Object System.Drawing.Point(($W - 244), ($H - 48))

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = 'Annuler'
    $btnCancel.Size = New-Object System.Drawing.Size(110, 30)
    $btnCancel.Location = New-Object System.Drawing.Point(($W - 128), ($H - 48))

    $form.Controls.AddRange(@($header, $sep, $body, $btnBack, $btnNext, $btnCancel))

    # ------------------------------------------------------------ etat commun #
    $st = @{
        State      = (Get-State)
        GameDir    = ''
        Action     = 'Install'    # Install | Repair | Uninstall
        Selection  = @()          # cles de modules
        Options    = @{}
        OptControls = @{}
        Page       = 0
        Done       = $false
        Running    = $false
    }

    $detected = $GamePath
    if (-not $detected -and $st.State -and $st.State.PSObject.Properties['gamePath']) { $detected = "$($st.State.gamePath)" }
    if (-not (Test-GamePath $detected)) { $detected = Find-GamePath }
    $st.GameDir = "$detected"

    # Filtre : l'etat peut mentionner un module retire de l'installeur depuis.
    $priorKeys = @()
    if ($st.State -and $st.State.PSObject.Properties['modules']) {
        $priorKeys = @(Select-KnownModuleKeys @((ConvertTo-Hashtable $st.State.modules).Keys))
    }
    $priorOptions = @{}
    if ($st.State -and $st.State.PSObject.Properties['options']) {
        $priorOptions = ConvertTo-Hashtable $st.State.options
    }

    if ($priorKeys.Count) { $st.Selection = $priorKeys }
    else { $st.Selection = Get-DefaultModuleKeys }

    # --------------------------------------------------------------- helpers #
    function New-Lbl($text, $x, $y, $w, $h) {
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $text
        $l.Location = New-Object System.Drawing.Point($x, $y)
        $l.Size = New-Object System.Drawing.Size($w, $h)
        return $l
    }

    # Ordre des pages, recalcule a chaque navigation : la page Action n'existe
    # que si une installation est deja presente, et les pages Mods/Options
    # disparaissent pour une reparation ou une desinstallation.
    function Get-PageFlow {
        $flow = @('game')
        if ($st.State) { $flow += 'action' }
        if ($st.Action -eq 'Install') { $flow += @('mods', 'options') }
        $flow += @('summary', 'run')
        return $flow
    }

    # ----------------------------------------------------------------- pages #

    function Show-PageGame {
        $lblTitle.Text = 'Dossier du jeu'
        $lblSub.Text = 'Indique le dossier contenant eldenring.exe.'

        $body.Controls.Add((New-Lbl 'Dossier du jeu' 18 14 200 20))

        $txt = New-Object System.Windows.Forms.TextBox
        $txt.Text = $st.GameDir
        $txt.Location = New-Object System.Drawing.Point(18, 36)
        $txt.Size = New-Object System.Drawing.Size(($W - 150), 22)
        $txt.Name = 'gamePath'

        $btn = New-Object System.Windows.Forms.Button
        $btn.Text = 'Parcourir'
        $btn.Location = New-Object System.Drawing.Point(($W - 126), 35)
        $btn.Size = New-Object System.Drawing.Size(100, 24)

        $status = New-Lbl '' 18 74 ($W - 40) 40

        $refresh = {
            if (Test-GamePath $txt.Text.Trim()) {
                $status.ForeColor = [System.Drawing.Color]::DarkGreen
                $status.Text = "eldenring.exe trouve."
            }
            elseif ($txt.Text.Trim()) {
                $status.ForeColor = [System.Drawing.Color]::Firebrick
                $status.Text = "eldenring.exe est introuvable dans ce dossier."
            }
            else {
                $status.ForeColor = [System.Drawing.Color]::Firebrick
                $status.Text = "Jeu non detecte : indique le dossier manuellement."
            }
            $btnNext.Enabled = (Test-GamePath $txt.Text.Trim())
        }

        $btn.Add_Click({
                $d = New-Object System.Windows.Forms.FolderBrowserDialog
                $d.Description = 'Selectionne le dossier contenant eldenring.exe'
                if ($d.ShowDialog() -eq 'OK') { $txt.Text = $d.SelectedPath; & $refresh }
            }.GetNewClosure())
        $txt.Add_TextChanged($refresh)

        # etat de l'installation existante
        $info = New-Lbl '' 18 124 ($W - 40) 90
        if ($st.State) {
            $info.ForeColor = [System.Drawing.Color]::DarkGreen
            $names = @()
            foreach ($k in $priorKeys) {
                $m = Get-Me3Module $k
                if ($m) { $names += $m.Name } else { $names += $k }
            }
            $info.Text = "Une installation existe deja sur cette machine.`r`n" +
            "Mods installes : $($names -join ', ')`r`n`r`n" +
            "L'etape suivante te proposera de la reparer, de la modifier ou de la retirer."
        }
        else {
            $info.ForeColor = [System.Drawing.Color]::DimGray
            $info.Text = "Aucune installation detectee sur cette machine.`r`n" +
            "L'assistant va poser me3 puis les mods que tu choisiras.`r`n`r`n" +
            "Rien n'est ecrit avant l'ecran de resume."
        }

        $body.Controls.AddRange(@($txt, $btn, $status, $info))
        & $refresh
    }

    function Save-PageGame {
        $txt = $body.Controls['gamePath']
        $st.GameDir = $txt.Text.Trim()
        return (Test-GamePath $st.GameDir)
    }

    function Show-PageAction {
        $lblTitle.Text = 'Que veux-tu faire ?'
        $lblSub.Text = 'Une installation existe deja sur cette machine.'

        $y = 16
        $group = New-Object System.Windows.Forms.Panel
        $group.Location = New-Object System.Drawing.Point(0, 0)
        $group.Size = New-Object System.Drawing.Size($W, $BodyHeight)
        $group.Name = 'actions'

        $defs = @(
            @{ V = 'Repair'; T = 'Reparer'; D = 'Retelecharge et redeploie les memes mods. Les identites locales et le mot de passe sont conserves.' }
            @{ V = 'Install'; T = 'Modifier les mods'; D = 'Choisis a nouveau les mods et leurs reglages. Les mods decoches seront retires proprement.' }
            @{ V = 'Uninstall'; T = 'Desinstaller'; D = 'Retire les mods, restaure les fichiers d''origine du jeu et supprime le raccourci.' }
        )
        foreach ($d in $defs) {
            $r = New-Object System.Windows.Forms.RadioButton
            $r.Text = $d.T
            $r.Tag = $d.V
            $r.Location = New-Object System.Drawing.Point(24, $y)
            $r.Size = New-Object System.Drawing.Size(400, 22)
            $r.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
            $r.Checked = ($st.Action -eq $d.V)
            $group.Controls.Add($r)
            $y += 24
            $lbl = New-Lbl $d.D 44 $y ($W - 90) 36
            $lbl.ForeColor = [System.Drawing.Color]::DimGray
            $group.Controls.Add($lbl)
            $y += 46
        }
        # Aucun bouton coche (etat improbable) : on retombe sur Reparer.
        if (-not ($group.Controls | Where-Object { $_ -is [System.Windows.Forms.RadioButton] -and $_.Checked })) {
            ($group.Controls | Where-Object { $_ -is [System.Windows.Forms.RadioButton] })[0].Checked = $true
        }
        $body.Controls.Add($group)
    }

    function Save-PageAction {
        $group = $body.Controls['actions']
        foreach ($c in $group.Controls) {
            if ($c -is [System.Windows.Forms.RadioButton] -and $c.Checked) { $st.Action = "$($c.Tag)" }
        }
        return $true
    }

    function Show-PageMods {
        $lblTitle.Text = 'Mods'
        $lblSub.Text = 'Coche les mods a installer. Les dependances sont ajoutees automatiquement.'

        $panel = New-Object System.Windows.Forms.Panel
        $panel.Location = New-Object System.Drawing.Point(0, 0)
        $panel.Size = New-Object System.Drawing.Size($W, ($BodyHeight - 4))
        $panel.AutoScroll = $true
        $panel.Name = 'mods'

        $y = 10
        foreach ($m in Get-AllModules) {
            $cb = New-Object System.Windows.Forms.CheckBox
            $cb.Text = "$($m.Name)   $($m.Version)"
            $cb.Tag = $m.Key
            $cb.Checked = ($st.Selection -contains $m.Key)
            $cb.Location = New-Object System.Drawing.Point(20, $y)
            $cb.Size = New-Object System.Drawing.Size(($W - 70), 22)
            $cb.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
            $panel.Controls.Add($cb)
            $y += 22

            $desc = New-Lbl $m.Summary 40 $y ($W - 90) 34
            $desc.ForeColor = [System.Drawing.Color]::DimGray
            $panel.Controls.Add($desc)
            $y += 34

            if ($m.TouchesGame) {
                $warn = New-Lbl 'Ecrit dans le dossier du jeu (sauvegarde et restauration assurees).' 40 $y ($W - 90) 18
                $warn.ForeColor = [System.Drawing.Color]::DarkGoldenrod
                $panel.Controls.Add($warn)
                $y += 18
            }
            $y += 8
        }
        $body.Controls.Add($panel)
    }

    function Save-PageMods {
        $panel = $body.Controls['mods']
        $keys = @()
        foreach ($c in $panel.Controls) {
            if ($c -is [System.Windows.Forms.CheckBox] -and $c.Checked) { $keys += "$($c.Tag)" }
        }
        if (-not $keys.Count) {
            [System.Windows.Forms.MessageBox]::Show('Selectionne au moins un mod.', 'Mods', 'OK', 'Warning') | Out-Null
            return $false
        }
        $st.Selection = @(Resolve-ModuleSelection $keys | ForEach-Object { $_.Key })
        return $true
    }

    function Show-PageOptions {
        $lblTitle.Text = 'Reglages'
        $lblSub.Text = 'Les reglages marques « identique » doivent correspondre chez tous les joueurs.'

        $panel = New-Object System.Windows.Forms.Panel
        $panel.Location = New-Object System.Drawing.Point(0, 0)
        $panel.Size = New-Object System.Drawing.Size($W, ($BodyHeight - 4))
        $panel.AutoScroll = $true
        $panel.Name = 'options'

        $mods = @(Resolve-ModuleSelection $st.Selection)
        $defaults = Resolve-Options -ModuleList $mods -Previous $priorOptions -Provided $st.Options
        $st.OptControls = @{}

        $y = 8
        foreach ($m in $mods) {
            if (-not $m.Options.Count) { continue }

            $h = New-Lbl $m.Name 18 $y ($W - 60) 20
            $h.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
            $panel.Controls.Add($h)
            $y += 24

            foreach ($o in $m.Options) {
                $tag = 'different chez chacun'
                if ($o.Shared) { $tag = 'identique chez tous' }
                $panel.Controls.Add((New-Lbl "$($o.Label)  ($tag)" 36 $y 380 18))

                $tb = New-Object System.Windows.Forms.TextBox
                $tb.Text = "$($defaults[$o.Key])"
                $tb.Location = New-Object System.Drawing.Point(420, ($y - 2))
                $tb.Size = New-Object System.Drawing.Size(240, 22)
                $panel.Controls.Add($tb)
                $st.OptControls[$o.Key] = $tb
                $y += 24

                if ($o.Help) {
                    $hl = New-Lbl $o.Help 36 $y (($W - 80)) 32
                    $hl.ForeColor = [System.Drawing.Color]::DimGray
                    $panel.Controls.Add($hl)
                    $y += 34
                }
                $y += 4
            }
            $y += 10
        }
        $body.Controls.Add($panel)
    }

    function Save-PageOptions {
        $vals = @{}
        foreach ($k in $st.OptControls.Keys) { $vals[$k] = $st.OptControls[$k].Text.Trim() }
        try {
            # Valide le typage tout de suite plutot qu'en pleine installation.
            [void](Resolve-Options -ModuleList (Resolve-ModuleSelection $st.Selection) -Previous $priorOptions -Provided $vals)
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Reglage invalide', 'OK', 'Warning') | Out-Null
            return $false
        }
        $st.Options = $vals
        return $true
    }

    function Show-PageSummary {
        $lblTitle.Text = 'Resume'
        $lblSub.Text = 'Rien n''a encore ete modifie. Verifie, puis lance.'

        $tb = New-Object System.Windows.Forms.TextBox
        $tb.Multiline = $true; $tb.ReadOnly = $true; $tb.ScrollBars = 'Vertical'
        $tb.Location = New-Object System.Drawing.Point(18, 10)
        $tb.Size = New-Object System.Drawing.Size(($W - 40), ($BodyHeight - 24))
        $tb.Font = New-Object System.Drawing.Font('Consolas', 9)
        $tb.BackColor = [System.Drawing.Color]::White

        $sb = New-Object System.Text.StringBuilder
        [void]$sb.AppendLine("Dossier du jeu")
        [void]$sb.AppendLine("   $($st.GameDir)")
        [void]$sb.AppendLine()

        if ($st.Action -eq 'Uninstall') {
            [void]$sb.AppendLine('Action : DESINSTALLATION')
            [void]$sb.AppendLine()
            [void]$sb.AppendLine('Seront retires :')
            foreach ($k in $priorKeys) {
                $m = Get-Me3Module $k
                $n = $k
                if ($m) { $n = $m.Name }
                [void]$sb.AppendLine("   - $n")
            }
            [void]$sb.AppendLine('   - le profil me3 et le raccourci bureau')
            [void]$sb.AppendLine()
            [void]$sb.AppendLine('Les fichiers d''origine du jeu seront restaures depuis leur sauvegarde.')
            if ($st.State -and $st.State.PSObject.Properties['me3InstalledByUs'] -and $st.State.me3InstalledByUs) {
                [void]$sb.AppendLine('me3 sera retire : c''est cet installeur qui l''avait pose.')
            }
            else {
                [void]$sb.AppendLine('me3 sera conserve : il etait deja present avant cet installeur.')
            }
            $btnNext.Text = 'Desinstaller'
        }
        else {
            $mods = @(Resolve-ModuleSelection $st.Selection)
            $verb = 'INSTALLATION'
            if ($st.Action -eq 'Repair') { $verb = 'REPARATION' }
            [void]$sb.AppendLine("Action : $verb")
            [void]$sb.AppendLine()

            $me3v = Get-Me3Version
            if ($me3v) { [void]$sb.AppendLine("me3 : deja present ($me3v), conserve") }
            else { [void]$sb.AppendLine("me3 : $($script:Me3Version) sera telecharge et installe") }
            [void]$sb.AppendLine()

            [void]$sb.AppendLine('Mods :')
            foreach ($m in $mods) {
                [void]$sb.AppendLine(("   {0,-26} {1}" -f $m.Name, $m.Version))
            }
            $touchers = @($mods | Where-Object { $_.TouchesGame })
            if ($touchers.Count) {
                [void]$sb.AppendLine()
                [void]$sb.AppendLine('Ecrivent dans le dossier du jeu (avec sauvegarde) :')
                foreach ($m in $touchers) { [void]$sb.AppendLine("   - $($m.Name)") }
            }

            if ($st.Action -eq 'Install') {
                $opts = Resolve-Options -ModuleList $mods -Previous $priorOptions -Provided $st.Options
                [void]$sb.AppendLine()
                [void]$sb.AppendLine('Reglages :')
                foreach ($m in $mods) {
                    foreach ($o in $m.Options) {
                        $v = $opts[$o.Key]
                        if (-not $v) { $v = '(genere)' }
                        [void]$sb.AppendLine(("   {0,-26} {1}" -f $o.Label, $v))
                    }
                }
                $dropped = @($priorKeys | Where-Object { $st.Selection -notcontains $_ })
                if ($dropped.Count) {
                    [void]$sb.AppendLine()
                    [void]$sb.AppendLine('Seront retires (decoches) :')
                    foreach ($k in $dropped) {
                        $m = Get-Me3Module $k
                        $n = $k
                        if ($m) { $n = $m.Name }
                        [void]$sb.AppendLine("   - $n")
                    }
                }
            }
            else {
                [void]$sb.AppendLine()
                [void]$sb.AppendLine('Les reglages et les identites locales sont conserves.')
            }

            $btnNext.Text = 'Installer'
            if ($st.Action -eq 'Repair') { $btnNext.Text = 'Reparer' }
        }

        $tb.Text = $sb.ToString()
        $body.Controls.Add($tb)
    }

    function Show-PageRun {
        $lblTitle.Text = 'Progression'
        $lblSub.Text = 'Ne ferme pas cette fenetre.'

        $log = New-Object System.Windows.Forms.TextBox
        $log.Multiline = $true; $log.ReadOnly = $true; $log.ScrollBars = 'Vertical'
        $log.Location = New-Object System.Drawing.Point(18, 10)
        $log.Size = New-Object System.Drawing.Size(($W - 40), ($BodyHeight - 24))
        $log.Font = New-Object System.Drawing.Font('Consolas', 9)
        $log.BackColor = [System.Drawing.Color]::White
        $body.Controls.Add($log)

        $btnBack.Enabled = $false
        $btnNext.Enabled = $false
        $btnCancel.Enabled = $false
        $st.Running = $true

        $script:LogSink = {
            param($line)
            $log.AppendText("$line`r`n")
            $log.SelectionStart = $log.TextLength
            $log.ScrollToCaret()
            [System.Windows.Forms.Application]::DoEvents()
        }

        $ok = $true
        try {
            if ($st.Action -eq 'Uninstall') {
                Invoke-Removal
            }
            else {
                $mods = @(Resolve-ModuleSelection $st.Selection)
                $opts = Resolve-Options -ModuleList $mods -Previous $priorOptions -Provided $st.Options
                Invoke-Setup -RunMode $st.Action -GameDir $st.GameDir -SelectedModules $mods -Options $opts
            }
        }
        catch {
            $ok = $false
            Write-Log $_.Exception.Message -Level Error
        }
        finally {
            $script:LogSink = $null
            $st.Running = $false
        }

        if ($ok) {
            $lblSub.Text = 'Termine.'
            $lblSub.ForeColor = [System.Drawing.Color]::DarkGreen
        }
        else {
            $lblSub.Text = 'Echec. Lis le journal ci-dessus.'
            $lblSub.ForeColor = [System.Drawing.Color]::Firebrick
        }
        $st.Done = $true
        $btnNext.Text = 'Terminer'
        $btnNext.Enabled = $true
        $btnCancel.Enabled = $true
        $btnCancel.Text = 'Fermer'
    }

    # ------------------------------------------------------------ navigation #

    $render = {
        $body.Controls.Clear()
        $lblSub.ForeColor = [System.Drawing.Color]::DimGray
        $flow = Get-PageFlow
        $page = $flow[$st.Page]

        $btnBack.Enabled = ($st.Page -gt 0)
        $btnNext.Text = 'Suivant >'
        $btnNext.Enabled = $true

        switch ($page) {
            'game' { Show-PageGame }
            'action' { Show-PageAction }
            'mods' { Show-PageMods }
            'options' { Show-PageOptions }
            'summary' { Show-PageSummary }
            'run' { Show-PageRun }
        }
    }

    $btnNext.Add_Click({
            if ($st.Done) { $form.Close(); return }
            $flow = Get-PageFlow
            $page = $flow[$st.Page]

            $ok = $true
            switch ($page) {
                'game' { $ok = Save-PageGame }
                'action' { $ok = Save-PageAction }
                'mods' { $ok = Save-PageMods }
                'options' { $ok = Save-PageOptions }
            }
            if (-not $ok) { return }

            # Le flux depend de l'action choisie : on le relit apres coup.
            $flow = Get-PageFlow
            if ($st.Page -lt ($flow.Count - 1)) {
                $st.Page++
                & $render
            }
        })

    $btnBack.Add_Click({
            if ($st.Page -gt 0) { $st.Page--; & $render }
        })

    $btnCancel.Add_Click({ $form.Close() })

    $form.Add_FormClosing({
            param($s, $e)
            if ($st.Running) { $e.Cancel = $true }
        })

    & $render
    [void]$form.ShowDialog()
    $script:LogSink = $null
}
