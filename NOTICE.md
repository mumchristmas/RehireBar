# Attribution

RehireBar is derived from [Codex Status Touch Bar](https://github.com/binlabongbom/codex-status-touch-bar), originally created by Wongsakorn Uphonram and distributed under the MIT License.

The original copyright and permission notice is preserved in `LICENSE`. RehireBar includes subsequent changes by RehireBar contributors. Source distributions retain both files; application bundles include them in `Contents/Resources/`.

RehireBar is an independent community project and is not affiliated with Apple or OpenAI.

## Hero images

The English and Chinese hero images in `docs/assets/rehirebar-hero-en.png` and `docs/assets/rehirebar-hero-zh-CN.png` use a [MacBook Pro Touch Bar photograph by Nik](https://unsplash.com/photos/black-and-gray-lenovo-laptop-3LJdk7FlqrI), available under the [Unsplash License](https://unsplash.com/license).

These images are AI-assisted illustrative composites: the photograph was reframed and the RehireBar interface was rendered from screenshots with example task names and values. The separate `rehirebar-touchbar-en.png` and `rehirebar-touchbar-zh-CN.png` files are complete, uncropped captures of the actual Touch Bar interface.

The application embeds [Sparkle](https://github.com/sparkle-project/Sparkle), an
open-source macOS update framework. Its full copyright, permission, and bundled
component notices are preserved in `Contents/Resources/Sparkle-LICENSE.txt` in
each application package. Swift Package Manager pins the framework distribution.

The user-triggered Touch Bar presentation behavior was inspired by
[Empsunrise](https://github.com/Empsunrise)'s
[Codex Status Touch Bar PR #2](https://github.com/binlabongbom/codex-status-touch-bar/pull/2).
Thank you for identifying unwanted reopening after dismissal and proposing that
presentation recovery stay within an explicit user action. RehireBar adapts that
principle while retaining independent task monitoring and state-expiry checks.
