#private  
function set-WebSecurity () {
	[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
}

#public
function New-GitRepo () {
	param(
		[Parameter(mandatory = $true)] [string]$name
	)

	$postparams = "{`"name`":`"$($name)`"}"

	return Invoke-RestMethod -Uri "https://api.github.com/user/repos" -Headers (Test-GitAuth) -Method POST -Body $postparams
}

#public
function get-GitRepos () {
	return Invoke-RestMethod -Uri "https://api.github.com/user/repos" -Headers (Test-GitAuth)
}

#public
function get-GitRepo () {
	param(
		[string]$ProjectPath = ((Get-Item -Path ".\").FullName)
	)
	$repos = get-GitRepos
	$config = (Get-Content "$($ProjectPath)\.git\config").split("`n")
	$urls = ($config | Where-Object { $_ -like "*url = *" })
	$giturl = ($urls | Where-Object { $_ -like "*github*" }).split("=").Trim()[1].Replace(".git","")

	if ($repos.html_url.Contains($giturl)) {
        $RepoData=($repos | where-object {$_.html_url.Contains($giturl)})
         Add-Member -InputObject $RepoData -MemberType NoteProperty -Name collaborators_data -Value (get-GitRepoCollaborators -FullName "$($RepoData.full_name)")

        return $RepoData
	}
	throw [System.UriFormatException]"The repo $($giturl) Does not exsist"
	break all
}

#private
function get-GitRepoCollaborators (){
	param(
		#Example: Mentaleak\PSGit
		[string]$FullName
	)
    return Invoke-RestMethod -Uri "https://api.github.com/repos/$($FullName)/collaborators" -Headers (Test-GitAuth)
}

#private
function get-GitRepoContributors (){
	param(
		#Example: Mentaleak\PSGit
		[string]$FullName
	)
    return Invoke-RestMethod -Uri "https://api.github.com/repos/$($FullName)/contributors" -Headers (Test-GitAuth)
}
#private 
function Test-GitAuth () {
	param(
		[switch]$nobreak
	)
	if ($Global:GitAuth) {
		return $Global:GitAuth

	}
	Write-Host "Please run Connect-Github first"
	if (!$nobreak) {
		break all
	}
	else
	{
		return $false
	}
}

#private
function Get-GitAuthHeader () {
	param(
		[string]$user,
		[string]$pass,
		[pscredential]$cred
	)
	if ($cred)
	{
		$user = $cred.UserName
		$basicAuthValue = "Basic $([System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes("$($user):$([System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($($cred.Password))))")))"
	}
	elseif ($user -and $pass)
	{
		$pair = "${user}:${pass}"
		$bytes = [System.Text.Encoding]::ASCII.GetBytes($pair)
		$base64 = [System.Convert]::ToBase64String($bytes)
		$basicAuthValue = "Basic $base64"
	}
	else {
		throw [System.InvalidOperationException]"Please Provide either (-cred) or (-user and -pass)"
	}
	$headers = @{ Authorization = $basicAuthValue }
	return $headers
}


#connects to github for API
function Connect-github () {
	set-WebSecurity
	$tmpheader = Get-GitAuthHeader -cred (Get-Credential)
	try { $userdata = Invoke-RestMethod -Uri "https://api.github.com/user" -Headers $tmpheader }
	catch {
		throw [System.UnauthorizedAccessException]"$((($_.ErrorDetails.Message) | ConvertFrom-Json).message)"
		break all
	}
	Write-Host "Connection Successful"
	Write-Host "Login: $($userdata.Login)"
	Write-Host "URL: $($userdata.html_url)"
	$global:GitAuth = $tmpheader
}


# Binds folder to github
# requires git
function Copy-GitRepo () {
	param(
		#Example: C:\Scripts\
		[Parameter(mandatory = $true)] [string]$LocalPath,
		#Example: https://github.com/{USERNAME}/{REPO}
		[Parameter(mandatory = $true)] [string]$RemoteRepo
	)
	if (!(Test-Path $LocalPath))
	{
		New-Item -ItemType Directory -Force -Path $LocalPath
	}
	Set-Location $LocalPath
	git clone $RemoteRepo
}

#Example:
#Get-GitRepo -LocalPath "C:\Scripts\" -RemoteRepo "https://github.com/Mentaleak/PSGit"

#updates git repo
function Add-GitAutoCommitPush () {
	param(
		#Example: C:\Scripts\
		[string]$ProjectPath = ((Get-ChildItem ($psISE.CurrentFile.FullPath)).Directory.FullName),
		$fixes = $null
	)

	#Write-Host "Test Local"
	if (test-GitLocal -ProjectPath $ProjectPath) {
		#Write-Host "Test remote"
		if (test-GitRemote -ProjectPath $ProjectPath) {

			Set-Location $ProjectPath
			#get diff list, including new files

			#set config user
			#Write-Host "getuserdata"
			$gituser = get-gituserdata
			git config --global user.name "$($gituser.UserData.login)"
			git config --global user.email "$($gituser.UserEmail.email)"

			#Write-Host "Get Diff"
			$gitStatus = (git status).split("`n")
			git add -N *
			$difflist = (git diff)
			#Write-Host "Compare Diff $difflist"
			if ($difflist) {
				$difflist = (git diff).split("`n")
				Write-Host "$($difflist.Count) Differences Found"

				#look at each file add and commit file with changes
				foreach ($diff in $difflist.where{ ($_.Contains("diff --git")) -and !($_.Contains("(`"diff --git`")")) })
				{
					$fileName = $diff.Substring($diff.IndexOf("b/") + 2,($diff.Length - $diff.IndexOf("b/") - 2))
					$diffdata = (git diff $fileName).split("`n")
					$functionlist = Get-functions $fileName

					$mods = $diffdata | Where-Object { ($_[0] -eq "+" -or $_[0] -eq "-") -and ($_ -match "[a-zA-Z0-9]") }
					$ChangedFunctions = @()
					foreach ($mod in $mods) {
						foreach ($fn in $functionlist) {
							if ($fn.definition.Contains($mod.Substring(1,$mod.Length - 1))) {
								$ChangedFunctions += "$($fn.name)"
							}
						}
					}
					$ChangedFunctions = $ChangedFunctions | sort | Get-Unique

					if ($difflist[$difflist.IndexOf($diff) + 1].Contains("new file")) {
						$Message = " Added " + $fileName

					} else {
						$Message = " Modified " + $fileName

					}
					if ($ChangedFunctions -ne $null)
					{
						$FunctionString = $ChangedFunctions -join "`n"
						$Description = "Changed functions: `n$($FunctionString)"
					}
					else
					{
						$description = "Content Modified"
					}
					if ($fixes -ne $null)
					{
						$fixes = $fixes | sort | Get-Unique
						$fixed = $fixes -join " and resolves #"
						$description += "`n This Commit Resolves #$($fixed)"
					}
					Write-Host "$fileName" -ForegroundColor Yellow
					Write-Host "$Message"
					Write-Host "$Description" -ForegroundColor Gray
					git add $fileName
					git commit -m "$Message" -m "$Description"
				}
				$DeletedFiles = ($gitStatus.where{ ($_.Contains("deleted:")) })
				if ($deletedFiles)
				{
					$DeletedFiles = $DeletedFiles.split(":")[1].Trim()
				}
				foreach ($deletedfile in $deletedfiles) {
					Write-Host "$deletedfile" -ForegroundColor red
					Write-Host "DELETED"
				}

				git push 2> $null


			}


		}
	}
}

#private
function test-GitLocal () {
	param(
		#Example: C:\Scripts\
		[string]$ProjectPath = ((Get-Item -Path ".\").FullName)
	)
	if ((Test-Path "$($ProjectPath)\.git"))
	{
		return $true
	}
	else
	{
		throw [System.IO.FileNotFoundException]"NO .git Folder present"
		return $false
	}
}

#private
function test-GitRemote () {
	param(
		#Example: C:\Scripts\
		[string]$ProjectPath = ((Get-Item -Path ".\").FullName)
	)
	$repos = get-GitRepos
	$config = (Get-Content "$($ProjectPath)\.git\config").split("`n")
	$urls = ($config | Where-Object { $_ -like "*url = *" })
	$giturl = ($urls | Where-Object { $_ -like "*github*" }).split("=").Trim()[1].Replace(".git","")

	if ($repos.html_url.Contains($giturl)) {
		return $true

	}
	throw [System.UriFormatException]"The repo $($giturl) Does not exsist"
	break all
}

#returns functions from file
function Get-functions () {
	param(
		[Parameter(mandatory = $true)] [string]$filePath
	)

	$file = Get-ChildItem $filePath
	$oldarray = Get-ChildItem function:\
	$acceptableExtensions = @(".dll",".ps1",".psm1",".psd1",".cdxml",".xaml")

	if ($acceptableExtensions.Contains($file[0].Extension)) {
		Import-Module $($file.FullName)
		$newarray = Get-ChildItem function:\
		$functions = ($newarray | Where-Object { $oldarray -notcontains $_ })
		Remove-Module $($file.BaseName)
		return $functions
	}

	else {
		Write-Host "$($file.FullName) is not a Powershell File"
		return @()

	}


}

#Throws an Error
function remove-gitRepo () {
	param(
		[Parameter(mandatory = $true)] [string]$name
	)
	throw [System.NotSupportedException]"Somethings are just too powerful, Make your own mistakes, I'm not helping"
}

#gets data of user
function get-gituserdata () {
	$userdata = Invoke-RestMethod -Uri "https://api.github.com/user" -Headers (Test-GitAuth)
	$useremail = Invoke-RestMethod -Uri "https://api.github.com/user/emails" -Headers (Test-GitAuth)
	$user = New-Object PSObject -Property @{
		UserData = $userdata
		UserEmail = $useremail
	}

	return $user
}


