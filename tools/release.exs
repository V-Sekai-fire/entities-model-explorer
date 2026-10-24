#!/usr/bin/env elixir
# Build, test and publish the desktop viewers (SkinTokens viewer and walk-mode viewer) in one run.
#
#   pixi run release                          from the smoke-water root (release.exs is linked
#                                             there by the manifest); publishes to branch dev
#   pixi run release --publish main           publish to main instead (the Spaces link main)
#   pixi run release --publish none           build and test only
#   pixi run release --ref <model-explorer ref>   default origin/main
#   pixi run release --resume <dir>           continue a stopped run; finished steps are skipped
#                                             (new runs go under $RELEASE_ROOT, default D: on the
#                                             WSL desk, else <root>/.release)
#   pixi run release --until <step>           stop after a step (see @steps)
#   pixi run release --branch <repo>=<branch> take that guest's ELF from its newest green run on
#                                             <branch> instead of main (a release candidate);
#                                             repeat for more repos, the source is recorded
#
# Run it on the WSL desk: the Windows tests run on this machine, the macOS image is built and
# tested on the Mac over ssh (RELEASE_MAC, default ernest.lee@100.64.202.51), the Linux test runs
# in WSLg. Every input comes from a green main CI run, a release, or a pinned checkout, and its
# source is written to <dir>/SOURCES.txt:
#   engine     newest *-double.* release of V-Sekai-fire/service-godot-build (SHA256SUMS checked)
#   sandbox    newest green Builds run on V-Sekai-fire/godot-sandbox main
#   guests     newest green guest run on main of interactor-skintokens-guest, -motion-guest,
#              -motion-matching-guest (and its clip data at the same commit), interactor-headfit
#   mujoco     project/plans/mujoco.double.elf at interactor-mujoco-sandbox-demo origin/main
#   usd        usd.elf has no CI build: it is carried from the published walk-mode viewer's pck
#   weights    chibifire/SkinTokens-GGUF-BF16 (its SHA256SUMS checked)
# Gates, in order (the run stops at the first failure and says which):
#   each ELF in the exported pck equals its input; Windows, macOS image and Linux start and report
#   their features; the SkinTokens viewer rigs giraffe.glb (AUTO-RIG-OK); both viewers walk
#   three-vrm-girl.vrm (VRM 0.x, six skins: MOVE-OK), on Windows below @max_private_mb of private
#   memory; then the upload gate (space_gate.py: blocked words, licence coverage, live sha256).
# Tokens come from OpenBao (bao-mint-github, bao-hf-token or bao-env) and never reach argv.
# Functions return {:ok, value} or {:error, reason}; nothing raises.

defmodule Release do
  @steps ~w(engine sandbox guests weights source notices pck package dmg test_windows test_mac test_linux publish)
  @max_private_mb 8192
  @viewers [
    %{key: "skintokens", app: "skintokens-viewer", name: "SkinTokens Viewer",
      repo: "chibifire/interactor-skintokens-viewer", rig: true, mac_zip: true},
    %{key: "walk-mode", app: "walk-mode-viewer", name: "Walk Mode Viewer",
      repo: "chibifire/interactor-walk-mode-viewer", rig: false, mac_zip: false}
  ]
  @weights ~w(mesh-encoder.gguf skin-vae.gguf tokenrig.gguf)
  @engine_files ~w(godot.linuxbsd.editor.double.x86_64 godot.linuxbsd.template_release.double.x86_64
                   godot.macos.template_release.double.arm64 godot.windows.template_release.double.x86_64.llvm.exe)
  @guests [
    {"interactor-skintokens-guest", "skintokens-elf-", "skintokens.elf"},
    {"interactor-motion-guest", "motion-elf-", "motion.elf"},
    {"interactor-motion-matching-guest", "mm-elf-", "mm.elf"},
    {"interactor-headfit", "headfit-elf-", "headfit.elf"}
  ]

  def main(argv) do
    case run(argv) do
      {:ok, dir} ->
        IO.puts("RELEASE-OK #{dir}")
        0

      {:error, reason} ->
        IO.puts(:stderr, "RELEASE-FAIL #{format(reason)}")
        1
    end
  end

  defp format(r) when is_binary(r), do: r
  defp format(r), do: inspect(r)

  defp run(argv) do
    {opts, _, bad} =
      OptionParser.parse(argv, strict: [publish: :string, ref: :string, resume: :string, until: :string, branch: :keep])

    with :ok <- if(bad == [], do: :ok, else: {:error, "unknown options #{inspect(bad)}"}),
         {:ok, root} <- workspace_root(),
         publish = opts[:publish] || "dev",
         :ok <- if(publish in ~w(none dev main), do: :ok, else: {:error, "--publish is none, dev or main"}),
         until = opts[:until] || List.last(@steps),
         :ok <- if(until in @steps, do: :ok, else: {:error, "--until is one of #{Enum.join(@steps, " ")}"}),
         dir = opts[:resume] || Path.join(release_root(root), stamp()),
         :ok <- File.mkdir_p(Path.join(dir, ".done")) do
      ctx = %{root: root, dir: dir, publish: publish, ref: opts[:ref] || "origin/main",
              mac: System.get_env("RELEASE_MAC") || "ernest.lee@100.64.202.51", id: Path.basename(dir),
              branches: Map.new(Keyword.get_values(opts, :branch), &List.to_tuple(String.split(&1, "=", parts: 2)))}
      IO.puts("release #{ctx.id} in #{dir} (publish: #{publish})")
      steps = Enum.take_while(@steps, &(&1 != until)) ++ [until]

      Enum.reduce_while(steps, {:ok, dir}, fn step, acc ->
        marker = Path.join([dir, ".done", step])

        if File.exists?(marker) do
          IO.puts("== #{step}: done in an earlier run")
          {:cont, acc}
        else
          IO.puts("== #{step}")

          case apply(__MODULE__, String.to_atom("step_" <> step), [ctx]) do
            :ok -> File.write(marker, stamp()); {:cont, acc}
            {:error, reason} -> {:halt, {:error, {String.to_atom(step), reason}}}
          end
        end
      end)
    end
  end

  defp workspace_root do
    start = Path.expand(__DIR__)

    Stream.iterate(start, &Path.dirname/1)
    |> Enum.take(8)
    |> Enum.find(&File.dir?(Path.join(&1, ".repo")))
    |> case do
      nil -> {:error, "no .repo above #{start}: run from the smoke-water root"}
      root -> {:ok, root}
    end
  end

  # A release folder holds about 8 GB (three packages per viewer plus the weights). RELEASE_ROOT
  # picks where; on the WSL desk the default is D:, which has the room the WSL disk lacks.
  defp release_root(root) do
    cond do
      r = System.get_env("RELEASE_ROOT") -> r
      File.dir?("/mnt/d") -> "/mnt/d/smoke-water-release"
      true -> Path.join(root, ".release")
    end
  end

  defp stamp, do: Calendar.strftime(DateTime.utc_now(), "%Y%m%d-%H%M")

  # ---- steps ---------------------------------------------------------------------------------

  def step_engine(ctx) do
    d = Path.join(ctx.dir, "engine")

    with {:ok, tok} <- gh_token("V-Sekai-fire"),
         {:ok, json} <- cap("gh", ~w(release list -R V-Sekai-fire/service-godot-build -L 30 --json tagName), gh_env(tok)),
         {:ok, list} <- decode(json),
         tag when is_binary(tag) <- Enum.find_value(list, &(String.contains?(&1["tagName"], "-double.") && &1["tagName"])) || {:error, "no double release"},
         :ok <- File.mkdir_p(d),
         pats = Enum.flat_map(["SHA256SUMS" | @engine_files], &["-p", &1]),
         {:ok, _} <- cap("gh", ["release", "download", tag, "-R", "V-Sekai-fire/service-godot-build", "-D", d, "--clobber" | pats], gh_env(tok)),
         {:ok, _} <- cap("sha256sum", ["-c", "SHA256SUMS", "--ignore-missing", "--strict"], [], d),
         :ok <- Enum.reduce_while(@engine_files, :ok, fn f, _ -> chmod_x(Path.join(d, f)) end),
         {:ok, _} <- File.copy(Path.join(ctx.root, "4-entities/model-explorer/LICENSE"), Path.join(d, "LICENSE-model-explorer.txt")) do
      source(ctx, "engine V-Sekai-fire/service-godot-build #{tag}")
    end
  end

  def step_sandbox(ctx) do
    d = Path.join(ctx.dir, "sandbox")
    names = ~w(godot-sandbox-macos-universal-double godot-sandbox-windows-x86_64-double godot-sandbox-linux-x86_64-double)

    with {:ok, tok} <- gh_token("V-Sekai-fire"),
         {:ok, run, sha} <- green_run(tok, "V-Sekai-fire/godot-sandbox", "Builds"),
         :ok <- clean(d),
         :ok <- Enum.reduce_while(names, :ok, fn n, _ ->
           case cap("gh", ["run", "download", run, "-R", "V-Sekai-fire/godot-sandbox", "-n", n, "-D", Path.join(d, n)], gh_env(tok)) do
             {:ok, _} -> {:cont, :ok}
             e -> {:halt, e}
           end
         end),
         :ok <- flatten_libs(d),
         :ok <- need(d, ~w(libgodot_riscv.macos.template_release.double.universal.framework
                          libgodot_riscv.windows.template_release.double.x86_64.dll
                          libgodot_riscv.linux.template_release.double.x86_64.so)) do
      source(ctx, "sandbox V-Sekai-fire/godot-sandbox Builds run #{run} (#{sha})")
    end
  end

  def step_guests(ctx) do
    d = Path.join(ctx.dir, "elf")

    with {:ok, tok} <- gh_token("V-Sekai-fire"),
         :ok <- clean(d),
         :ok <- Enum.reduce_while(@guests, :ok, fn {repo, prefix, file}, _ ->
           case guest(ctx, tok, repo, prefix, file, d) do
             :ok -> {:cont, :ok}
             e -> {:halt, e}
           end
         end),
         :ok <- mujoco(ctx, d),
         :ok <- usd_from_published(ctx, d),
         :ok <- mm_data(ctx, d) do
      :ok
    end
  end

  defp guest(ctx, tok, repo, prefix, file, d) do
    r = "V-Sekai-fire/" <> repo

    with {:ok, run, sha} <- green_run(tok, r, "guest", Map.get(ctx.branches, repo, "main")),
         {:ok, json} <- cap("gh", ["api", "repos/#{r}/actions/runs/#{run}/artifacts"], gh_env(tok)),
         {:ok, %{"artifacts" => arts}} <- decode(json),
         name when is_binary(name) <- Enum.find_value(arts, &(String.starts_with?(&1["name"], prefix) && &1["name"])) || {:error, "#{r} run #{run} has no #{prefix} artifact"},
         tmp = Path.join(d, "ci-" <> repo),
         {:ok, _} <- cap("gh", ["run", "download", run, "-R", r, "-n", name, "-D", tmp], gh_env(tok)),
         {:ok, _} <- File.copy(Path.join(tmp, file), Path.join(d, file)) do
      if repo == "interactor-motion-matching-guest", do: File.write(Path.join(d, "mm.sha"), sha)
      source(ctx, "#{file} #{r} #{Map.get(ctx.branches, repo, "main")} guest run #{run} artifact #{name}")
    end
  end

  defp mujoco(ctx, d) do
    c = Path.join(ctx.root, "3-interactor/mujoco-sandbox-demo")
    out = Path.join(d, "mujoco.elf")

    with {:ok, _} <- cap("git", ["-C", c, "fetch", "-q", "origin", "main"]),
         {:ok, sha} <- cap("git", ["-C", c, "rev-parse", "FETCH_HEAD"]),
         {:ok, _} <- cap("sh", ["-c", "git -C \"$1\" cat-file blob \"$2:project/plans/mujoco.double.elf\" > \"$3\"", "sh", c, String.trim(sha), out]),
         {:ok, %{size: n}} when n > 100_000 <- File.stat(out) do
      source(ctx, "mujoco.elf interactor-mujoco-sandbox-demo #{String.slice(sha, 0, 12)} project/plans/mujoco.double.elf")
    else
      {:ok, %{size: n}} -> {:error, "mujoco.double.elf is #{n} bytes (a git-LFS pointer?)"}
      e -> e
    end
  end

  # usd.elf has no CI build. Carry it from the published walk-mode viewer (its Windows zip is the
  # smallest package holding the pck), after checking that zip against the repo's SHA256SUMS.
  defp usd_from_published(ctx, d) do
    repo = "chibifire/interactor-walk-mode-viewer"
    zip = Path.join(d, "previous-walk-mode-windows.zip")

    with {:ok, tok} <- hf_token(),
         {:ok, sums} <- hf_get(tok, repo, "SHA256SUMS", Path.join(d, "previous-SHA256SUMS")),
         want when is_binary(want) <- sum_for(sums, "walk-mode-viewer-windows-x86_64.zip") || {:error, "#{repo} SHA256SUMS lacks the Windows zip"},
         {:ok, _} <- hf_get(tok, repo, "walk-mode-viewer-windows-x86_64.zip", zip),
         {:ok, ^want} <- sha256(zip),
         {:ok, [{_, pck}]} <- :zip.extract(String.to_charlist(zip), [{:file_list, [~c"walk-mode-viewer.pck"]}, :memory]),
         {:ok, files} <- pck_files(pck),
         usd when is_binary(usd) <- files["usd.elf"] || {:error, "the published pck has no usd.elf"},
         :ok <- File.write(Path.join(d, "usd.elf"), usd),
         :ok <- File.rm(zip) do
      source(ctx, "usd.elf carried from #{repo} main walk-mode-viewer-windows-x86_64.zip #{String.slice(want, 0, 12)} (sha256 #{hex(:crypto.hash(:sha256, usd)) |> String.slice(0, 12)})")
    else
      {:ok, other} when is_binary(other) -> {:error, "the published walk-mode zip does not match its SHA256SUMS (#{String.slice(other, 0, 12)})"}
      e -> e
    end
  end

  defp mm_data(ctx, d) do
    c = Path.join(ctx.root, "3-interactor/motion-matching-guest")
    out = Path.join(d, "mmg")

    with {:ok, sha} <- File.read(Path.join(d, "mm.sha")),
         {:ok, _} <- cap("git", ["-C", c, "fetch", "-q", "origin", sha]),
         :ok <- clean(out),
         {:ok, _} <- cap("sh", ["-c", "git -C \"$1\" archive \"$2\" data | tar -x -C \"$3\"", "sh", c, sha, out]),
         :ok <- need(Path.join(out, "data"), ~w(kimodo-locomotion o3de-motionmatching)) do
      source(ctx, "clip data interactor-motion-matching-guest #{String.slice(sha, 0, 12)} data/")
    end
  end

  def step_weights(ctx) do
    d = Path.join(ctx.dir, "w")
    repo = "chibifire/SkinTokens-GGUF-BF16"

    with {:ok, tok} <- hf_token(),
         :ok <- File.mkdir_p(d),
         {:ok, sums} <- hf_get(tok, repo, "SHA256SUMS", Path.join(d, "SHA256SUMS")),
         :ok <- Enum.reduce_while(@weights, :ok, fn f, _ ->
           p = Path.join(d, f)
           want = sum_for(sums, f)

           with true <- is_binary(want) || {:error, "#{repo} SHA256SUMS lacks #{f}"},
                {:ok, have} <- (if File.exists?(p), do: sha256(p), else: {:ok, ""}),
                {:ok, _} <- (if have == want, do: {:ok, :kept}, else: hf_get(tok, repo, f, p)),
                {:ok, ^want} <- sha256(p) do
             {:cont, :ok}
           else
             {:ok, _} -> {:halt, {:error, "#{f} does not match #{repo} SHA256SUMS"}}
             e -> {:halt, e}
           end
         end) do
      source(ctx, "weights #{repo} main (SHA256SUMS checked)")
    end
  end

  def step_source(ctx) do
    me = Path.join(ctx.root, "4-entities/model-explorer")
    src = Path.join(ctx.dir, "model-explorer")

    with {:ok, _} <- cap("git", ["-C", me, "fetch", "-q", "origin"]),
         {:ok, sha} <- cap("git", ["-C", me, "rev-parse", ctx.ref <> "^{commit}"]),
         sha = String.trim(sha),
         _ = cap("git", ["-C", me, "worktree", "remove", "--force", src]),
         {:ok, _} <- cap("git", ["-C", me, "worktree", "add", "--detach", src, sha]),
         :ok <- need(src, ~w(tools/package_desktop.sh tools/licences/licgen.py)),
         {:ok, pkg} <- File.read(Path.join(src, "tools/package_desktop.sh")),
         true <- String.contains?(pkg, "walk-mode)") || {:error, "#{ctx.ref} predates the walk-mode package (tools/package_desktop.sh)"} do
      source(ctx, "viewer source V-Sekai-fire/entities-model-explorer #{sha} (#{ctx.ref})")
    end
  end

  def step_notices(ctx) do
    out = Path.join(ctx.dir, "notices")

    with :ok <- clean(out),
         {:ok, _} <- cap("python", [Path.join(ctx.dir, "model-explorer/tools/licences/licgen.py"), out]) do
      need(out, Enum.flat_map(@viewers, fn v -> Enum.map(~w(LICENSE.md NOTICE CITATION.cff), &Path.join(v.key, &1)) end))
    end
  end

  def step_pck(ctx) do
    out = Path.join(ctx.dir, "pck")
    elf = Path.join(ctx.dir, "elf")
    mmg = Path.join(elf, "mmg/data")

    env = [
      {"ENGINE", Path.join(ctx.dir, "engine")},
      {"GODOT", Path.join(ctx.dir, "engine/godot.linuxbsd.editor.double.x86_64")},
      {"SANDBOX", Path.join(ctx.dir, "sandbox")},
      {"ELF", Path.join(elf, "skintokens.elf")},
      {"USD_ELF", Path.join(elf, "usd.elf")},
      {"MOTION_ELF", Path.join(elf, "motion.elf")},
      {"HEADFIT_ELF", Path.join(elf, "headfit.elf")},
      {"MM_ELF", Path.join(elf, "mm.elf")},
      {"MUJOCO_ELF", Path.join(elf, "mujoco.elf")},
      {"MM_DATA", Path.join(mmg, "kimodo-locomotion") <> ":" <> Path.join(mmg, "o3de-motionmatching")}
    ]

    with {:ok, log} <- cap("sh", [Path.join(ctx.dir, "model-explorer/tools/package_desktop.sh"), "pck", out], env),
         true <- String.contains?(log, "PCK-OK") || {:error, "package_desktop.sh pck printed no PCK-OK"},
         {:ok, bin} <- File.read(Path.join(out, "skintokens-viewer.pck")),
         {:ok, files} <- pck_files(bin) do
      Enum.reduce_while(~w(skintokens.elf usd.elf motion.elf headfit.elf mm.elf mujoco.elf), :ok, fn f, _ ->
        case {File.read(Path.join(elf, f)), Map.fetch(files, f)} do
          {{:ok, b}, {:ok, b}} -> {:cont, :ok}
          {{:ok, _}, {:ok, _}} -> {:halt, {:error, "#{f} in the pck differs from its input"}}
          {{:ok, _}, :error} -> {:halt, {:error, "the pck lacks #{f}"}}
          {e, _} -> {:halt, e}
        end
      end)
    end
  end

  def step_package(ctx) do
    out = Path.join(ctx.dir, "pck")

    Enum.reduce_while(@viewers, :ok, fn v, _ ->
      env = [{"ENGINE", Path.join(ctx.dir, "engine")}, {"SANDBOX", Path.join(ctx.dir, "sandbox")},
             {"NOTICES", Path.join([ctx.dir, "notices", v.key])}]

      with {:ok, log} <- cap("sh", [Path.join(ctx.dir, "model-explorer/tools/package_desktop.sh"), "package", out, Path.join(ctx.dir, "w"), v.key], env),
           true <- String.contains?(log, "PACKAGE-OK") || {:error, "#{v.key}: no PACKAGE-OK"},
           # The archives are the release; the per-OS folders they were made from are not kept.
           :ok <- Enum.reduce_while(~w(macos windows linux), :ok, fn os, _ ->
             case File.rm_rf(Path.join([out, v.key, os])) do
               {:ok, _} -> {:cont, :ok}
               {:error, r, f} -> {:halt, {:error, "cannot remove #{f}: #{r}"}}
             end
           end) do
        {:cont, :ok}
      else
        e -> {:halt, e}
      end
    end)
  end

  def step_dmg(ctx) do
    Enum.reduce_while(@viewers, :ok, fn v, _ ->
      o = Path.join([ctx.dir, "pck", v.key])
      remote = "release-#{ctx.id}/#{v.key}"
      zip = "#{v.app}-macos-arm64.zip"
      dmg = "#{v.app}-macos-arm64.dmg"

      with {:ok, _} <- mac(ctx, "rm -rf ~/#{remote} && mkdir -p ~/#{remote}"),
           {:ok, _} <- cap("scp", ["-q", Path.join(o, zip), "#{ctx.mac}:#{remote}/#{zip}"]),
           {:ok, _} <- mac(ctx, dmg_script(v, remote, zip, dmg, ctx.id)),
           {:ok, _} <- cap("scp", ["-q", "#{ctx.mac}:#{remote}/#{dmg}", Path.join(o, dmg)]),
           :ok <- sums(o, v) do
        {:cont, :ok}
      else
        e -> {:halt, e}
      end
    end)
  end

  # One SHA256SUMS per viewer: the files that viewer publishes (walk-mode ships the dmg only).
  defp sums(o, v) do
    files = archives(v)

    Enum.reduce_while(files, {:ok, []}, fn f, {:ok, acc} ->
      case sha256(Path.join(o, f)) do
        {:ok, h} -> {:cont, {:ok, ["#{h}  #{f}\n" | acc]}}
        e -> {:halt, e}
      end
    end)
    |> case do
      {:ok, lines} -> File.write(Path.join(o, "SHA256SUMS"), lines |> Enum.reverse())
      e -> e
    end
  end

  defp archives(v) do
    mac = if v.mac_zip, do: ["#{v.app}-macos-arm64.zip", "#{v.app}-macos-arm64.dmg"], else: ["#{v.app}-macos-arm64.dmg"]
    mac ++ ["#{v.app}-windows-x86_64.zip", "#{v.app}-linux-x86_64.tar"]
  end

  defp dmg_script(v, remote, zip, dmg, id) do
    """
    set -eu
    cd ~/#{remote}
    rm -rf unz stage; mkdir unz; (cd unz && unzip -q ../#{zip})
    C="stage/#{v.name}.app/Contents"; mkdir -p "$C/MacOS" "$C/Resources" "$C/Frameworks"
    cp unz/#{v.app} "$C/MacOS/"; [ ! -d unz/w ] || cp -R unz/w "$C/MacOS/w"
    cp unz/#{v.app}.pck unz/LICENSE.md unz/NOTICE unz/CITATION.cff unz/LICENSE-model-explorer.txt "$C/Resources/"
    cp -R unz/libgodot_riscv.macos.template_release.double.universal.framework "$C/Frameworks/"
    cat > "$C/Info.plist" <<'P'
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
    <key>CFBundleExecutable</key><string>#{v.app}</string>
    <key>CFBundleIdentifier</key><string>com.chibifire.#{v.app}</string>
    <key>CFBundleName</key><string>#{v.name}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>#{id}</string>
    <key>CFBundleVersion</key><string>#{id}</string>
    <key>LSMinimumSystemVersion</key><string>11.0</string>
    <key>NSHighResolutionCapable</key><true/>
    </dict></plist>
    P
    plutil -lint "$C/Info.plist" >/dev/null
    find stage -name '._*' -delete; xattr -cr stage
    codesign --force --deep -s - "stage/#{v.name}.app"; codesign --verify --deep --strict "stage/#{v.name}.app"
    ln -s /Applications stage/Applications; cp unz/LICENSE.md unz/NOTICE unz/CITATION.cff stage/
    COPYFILE_DISABLE=1 hdiutil create -quiet -volname "#{v.name}" -srcfolder stage -fs APFS -format ULFO -ov #{dmg}
    hdiutil verify -quiet #{dmg}
    rm -rf unz stage
    echo DMG-OK
    """
  end

  def step_test_windows(ctx) do
    with {:ok, profile} <- cap("cmd.exe", ["/c", "echo %USERPROFILE%"], [], "/mnt/c"),
         {:ok, wpath} <- cap("wslpath", ["-u", String.trim(profile)]),
         base = Path.join([String.trim(wpath), "Desktop", "release-test-#{ctx.id}"]),
         :ok <- clean(base),
         :ok <- copy_models(ctx, base),
         {:ok, appdata} <- cap("cmd.exe", ["/c", "echo %APPDATA%"], [], "/mnt/c"),
         {:ok, moves} <- cap("wslpath", ["-u", String.trim(appdata) <> "\\Godot\\app_userdata\\ModelExplorer"]) do
      user = String.trim(moves)

      Enum.reduce_while(@viewers, :ok, fn v, _ ->
        d = Path.join(base, v.key)

        with :ok <- File.mkdir_p(d),
             # Windows' own tar reads the zip over \\wsl.localhost and writes C: natively: seconds,
             # where unzip through /mnt/c took minutes for the weights.
             {:ok, zipw} <- cap("wslpath", ["-w", Path.join([ctx.dir, "pck", v.key, "#{v.app}-windows-x86_64.zip"])]),
             {:ok, dw} <- cap("wslpath", ["-w", d]),
             {:ok, _} <- cap("tar.exe", ["-xf", String.trim(zipw), "-C", String.trim(dw)], [], "/mnt/c"),
             exe = Path.join(d, v.app <> ".exe"),
             {:ok, _} <- win_run(exe, ["--features-quit"], "VIEWER-FEATURES rig=#{v.rig}", Path.join(d, "features.log")),
             {:ok, _} <- (if v.rig, do: win_run(exe, [Path.join(base, "giraffe.glb"), "--auto-rig-quit"], "AUTO-RIG-OK", Path.join(d, "rig.log")), else: {:ok, :skipped}),
             :ok <- forget_moves(user),
             {:ok, peak} <- win_run(exe, [Path.join(base, "three-vrm-girl.vrm"), "--move-quit"], "MOVE-OK", Path.join(d, "walk.log")),
             true <- peak < @max_private_mb || {:error, "#{v.key} walk on Windows peaked at #{peak} MB private memory (limit #{@max_private_mb})"} do
          IO.puts("  windows #{v.key}: features, #{if v.rig, do: "rig, ", else: ""}walk OK, peak #{peak} MB private")
          {:cont, :ok}
        else
          e -> {:halt, e}
        end
      end)
    end
  end

  # The walk test must make the moves, not reuse an earlier run's.
  defp forget_moves(user) do
    for f <- Path.wildcard(Path.join(user, "three-vrm-girl*")) ++ Path.wildcard(Path.join(user, "moves/three-vrm-girl*")), do: File.rm(f)
    :ok
  end

  defp copy_models(ctx, base) do
    with {:ok, _} <- File.copy(Path.join(ctx.root, "3-interactor/skintokens-upstream/examples/giraffe.glb"), Path.join(base, "giraffe.glb")),
         {:ok, _} <- File.copy(Path.join(ctx.root, "3-interactor/test-godot-vrm-motion-checker/fire_motion_check/art/three_girl/three-vrm-girl.vrm"), Path.join(base, "three-vrm-girl.vrm")) do
      :ok
    end
  end

  # Start a Windows program with PowerShell, sample its private memory every second, and return
  # the peak in MB once its log holds `want`.
  defp win_run(exe, args, want, log) do
    ps = Path.join(Path.dirname(log), "run.ps1")
    mem = log <> ".mem"

    script = """
    param([string]$exe, [string]$log, [string]$mem, [string]$rest)
    $a = @("--") + ($rest -split ';')
    $p = Start-Process -FilePath $exe -ArgumentList $a -RedirectStandardOutput $log -RedirectStandardError "$log.err" -PassThru -NoNewWindow -WorkingDirectory (Split-Path $exe)
    $peak = 0
    while (-not $p.HasExited) { $p.Refresh(); $m = [int]($p.PrivateMemorySize64/1MB); if ($m -gt $peak) { $peak = $m }; Start-Sleep -Milliseconds 1000 }
    Set-Content $mem $peak
    """

    w = fn p -> case cap("wslpath", ["-w", p]) do {:ok, s} -> String.trim(s); _ -> p end end
    wargs = Enum.map(args, fn a -> if String.starts_with?(a, "/"), do: w.(a), else: a end)

    with :ok <- File.write(ps, script),
         {:ok, _} <- cap("powershell.exe", ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", w.(ps), "-exe", w.(exe), "-log", w.(log), "-mem", w.(mem), "-rest", Enum.join(wargs, ";")]),
         {:ok, out} <- File.read(log),
         err = (case File.read(log <> ".err") do {:ok, e} -> e; _ -> "" end),
         true <- String.contains?(out <> err, want) || {:error, "#{Path.basename(Path.dirname(log))} #{Path.basename(log)}: no #{want}; last lines: #{tail(out <> err)}"},
         {:ok, peak} <- File.read(mem) do
      {:ok, peak |> String.trim() |> String.to_integer()}
    end
  end

  def step_test_mac(ctx) do
    giraffe = Path.join(ctx.root, "3-interactor/skintokens-upstream/examples/giraffe.glb")
    girl = Path.join(ctx.root, "3-interactor/test-godot-vrm-motion-checker/fire_motion_check/art/three_girl/three-vrm-girl.vrm")
    t = "release-#{ctx.id}/test"

    with {:ok, _} <- mac(ctx, "rm -rf ~/#{t} && mkdir -p ~/#{t}"),
         {:ok, _} <- cap("scp", ["-q", giraffe, girl, "#{ctx.mac}:#{t}/"]) do
      Enum.reduce_while(@viewers, :ok, fn v, _ ->
        case mac(ctx, mac_test_script(v, ctx.id, t)) do
          {:ok, out} ->
            if String.contains?(out, "MAC-TEST-OK"),
              do: (IO.puts("  macos #{v.key}: #{tail(out)}"); {:cont, :ok}),
              else: {:halt, {:error, "macos #{v.key}: #{tail(out)}"}}

          e ->
            {:halt, e}
        end
      end)
    end
  end

  defp mac_test_script(v, id, t) do
    rig =
      if v.rig,
        do: ~s(open -n -W --stdout "$PWD/rig.log" --stderr "$PWD/rig.log" "$A" --args -- "$T/giraffe.glb" --auto-rig-quit; grep -q AUTO-RIG-OK rig.log || { echo "no AUTO-RIG-OK"; tail -5 rig.log; exit 1; }),
        else: ""

    """
    set -eu
    T=~/#{t}; cd ~/release-#{id}/#{v.key}
    rm -rf mnt app; mkdir mnt app
    hdiutil attach -quiet -nobrowse -readonly -mountpoint "$PWD/mnt" #{v.app}-macos-arm64.dmg
    codesign --verify --deep --strict "mnt/#{v.name}.app"
    ditto "mnt/#{v.name}.app" "app/#{v.name}.app"; hdiutil detach -quiet mnt
    A="$PWD/app/#{v.name}.app"
    open -n -W --stdout "$PWD/features.log" --stderr "$PWD/features.log" "$A" --args -- --features-quit
    grep -q "VIEWER-FEATURES rig=#{v.rig}" features.log || { echo "no VIEWER-FEATURES rig=#{v.rig}"; tail -5 features.log; exit 1; }
    #{rig}
    U="$HOME/Library/Application Support/Godot/app_userdata/ModelExplorer"; rm -f "$U"/three-vrm-girl* "$U"/moves/three-vrm-girl*
    open -n -W --stdout "$PWD/walk.log" --stderr "$PWD/walk.log" "$A" --args -- "$T/three-vrm-girl.vrm" --move-quit
    grep -q MOVE-OK walk.log || { echo "no MOVE-OK"; grep -E 'MOVE-(FAIL|STEP)' walk.log | tail -5; exit 1; }
    echo "MAC-TEST-OK $(grep -c 'MOVE-STEP.* ok$' walk.log) walk steps ok"
    """
  end

  def step_test_linux(ctx) do
    Enum.reduce_while(@viewers, :ok, fn v, _ ->
      d = Path.join([ctx.dir, "test-linux", v.key])
      log = Path.join(d, "features.log")
      env = [{"XDG_RUNTIME_DIR", "/mnt/wslg/runtime-dir"}, {"WAYLAND_DISPLAY", "wayland-0"}]

      with :ok <- clean(d),
           {:ok, _} <- cap("tar", ["-xf", Path.join([ctx.dir, "pck", v.key, "#{v.app}-linux-x86_64.tar"]), "-C", d]),
           {_, _} <- System.cmd(Path.join(d, v.app), ["--display-driver", "wayland", "--", "--features-quit"], env: env, stderr_to_stdout: true, cd: d, into: File.stream!(log)),
           {:ok, out} <- File.read(log),
           true <- String.contains?(out, "VIEWER-FEATURES rig=#{v.rig}") || {:error, "linux #{v.key}: no VIEWER-FEATURES rig=#{v.rig}: #{tail(out)}"} do
        IO.puts("  linux #{v.key}: features OK")
        {:cont, :ok}
      else
        e -> {:halt, e}
      end
    end)
  end

  def step_publish(%{publish: "none"}), do: (IO.puts("  --publish none: nothing uploaded"); :ok)

  def step_publish(ctx) do
    gate = Path.join(ctx.root, "3-interactor/skintokens-qlora/tools/space_gate.py")

    # A gate without REVISION would put a dev release on main.
    with {:ok, g} <- File.read(gate),
         true <- ctx.publish == "main" or String.contains?(g, "REVISION") ||
                   {:error, "#{gate} cannot commit to a branch (no REVISION): update the checkout"},
         {:ok, tok} <- hf_token() do
      Enum.reduce_while(@viewers, :ok, fn v, _ ->
        o = Path.join([ctx.dir, "pck", v.key])
        files = archives(v) ++ ~w(SHA256SUMS LICENSE.md NOTICE CITATION.cff)

        with :ok <- Enum.reduce_while(~w(LICENSE.md NOTICE CITATION.cff), :ok, fn f, _ ->
               case File.copy(Path.join([ctx.dir, "notices", v.key, f]), Path.join(o, f)) do
                 {:ok, _} -> {:cont, :ok}
                 e -> {:halt, e}
               end
             end),
             env = [{"HF_UPLOAD_TOKEN", tok}, {"REVISION", if(ctx.publish == "main", do: "", else: ctx.publish)},
                    {"MSG", "Release #{ctx.id}"}],
             {:ok, out} <- cap("sh", ["-c", "printf '%s' \"$HF_UPLOAD_TOKEN\" | python \"$@\"", "sh", gate, "push", v.repo, "model", o | files], env),
             true <- String.contains?(out, "live matches") || {:error, "#{v.repo}: #{tail(out)}"} do
          IO.puts("  #{v.repo}: #{out |> String.split("\n") |> Enum.find("", &String.starts_with?(&1, "commit"))}")
          {:cont, :ok}
        else
          e -> {:halt, e}
        end
      end)
    end
  end

  # ---- helpers -------------------------------------------------------------------------------

  # Godot pck (format 3 or 4, unencrypted): %{path => bytes}.
  def pck_files(<<0x43504447::little-32, version::little-32, _::binary-12, flags::little-32,
                  file_base::little-64, dir::little-64, _::binary>> = bin)
      when version in [3, 4] and Bitwise.band(flags, 1) == 0 do
    case bin do
      <<_::binary-size(^dir), count::little-32, entries::binary>> -> read_entries(entries, count, file_base, bin, %{})
      _ -> {:error, "pck directory offset is past the end"}
    end
  end

  def pck_files(_), do: {:error, "not an unencrypted Godot pck (format 3 or 4)"}

  defp read_entries(_, 0, _, _, acc), do: {:ok, acc}

  defp read_entries(<<len::little-32, path::binary-size(len), ofs::little-64, size::little-64,
                      _md5::binary-16, _flags::little-32, rest::binary>>, n, base, bin, acc) do
    name = path |> String.trim_trailing(<<0>>) |> String.replace_prefix("res://", "")

    if base + ofs + size <= byte_size(bin),
      do: read_entries(rest, n - 1, base, bin, Map.put(acc, name, binary_part(bin, base + ofs, size))),
      else: {:error, "pck entry #{name} is past the end"}
  end

  defp read_entries(_, _, _, _, _), do: {:error, "truncated pck directory"}

  defp cap(cmd, args, env \\ [], cd \\ nil) do
    case System.find_executable(cmd) do
      nil ->
        {:error, "#{cmd} is not on PATH"}

      exe ->
        opts = [env: env, stderr_to_stdout: true] ++ if(cd, do: [cd: cd], else: [])

        case System.cmd(exe, args, opts) do
          {out, 0} -> {:ok, out}
          {out, code} -> {:error, "#{cmd} #{Enum.take(args, 3) |> Enum.join(" ")} exited #{code}: #{tail(out)}"}
        end
    end
  end

  defp mac(ctx, script) do
    f = Path.join(ctx.dir, "mac-#{System.unique_integer([:positive])}.sh")

    with :ok <- File.write(f, script),
         {:ok, _} <- cap("scp", ["-q", f, "#{ctx.mac}:release-step.sh"]) do
      cap("ssh", ["-o", "BatchMode=yes", ctx.mac, "bash ~/release-step.sh"])
    end
  end

  defp tail(s), do: s |> String.split("\n", trim: true) |> Enum.take(-6) |> Enum.join(" | ")

  defp decode(json) do
    case :json.decode(json) do
      v -> {:ok, v}
    end
  rescue
    _ -> {:error, "not JSON: #{String.slice(json, 0, 120)}"}
  end

  defp green_run(tok, repo, workflow, branch \\ "main") do
    with {:ok, json} <- cap("gh", ["run", "list", "-R", repo, "--branch", branch, "--workflow", workflow, "--status", "success",
                                   "-L", "1", "--json", "databaseId,headSha"], gh_env(tok)),
         {:ok, [%{"databaseId" => id, "headSha" => sha}]} <- decode(json) do
      {:ok, Integer.to_string(id), sha}
    else
      {:ok, []} -> {:error, "no green #{workflow} run on #{repo} #{branch}"}
      e -> e
    end
  end

  defp gh_token(org) do
    helper = System.find_executable("bao-mint-github") || Path.expand("~/.local/bin/bao-mint-github")

    with true <- File.exists?(helper) || {:error, "no bao-mint-github on this machine"},
         {out, 0} <- System.cmd("sh", ["-c", "\"$0\" \"$1\" 2>/dev/null", helper, org]),
         [tok | _] <- String.split(out) do
      {:ok, tok}
    else
      {:error, _} = e -> e
      _ -> {:error, "bao-mint-github #{org} gave no token"}
    end
  end

  defp gh_env(tok), do: [{"GH_TOKEN", tok}]

  defp hf_token do
    case System.find_executable("bao-hf-token") do
      nil ->
        sh = ~S|eval "$(bao-env)" >/dev/null 2>&1; bao kv get -field=token -mount=secret "agents-own/$BAO_CN/huggingface-token"|

        case System.cmd("sh", ["-c", sh]) do
          {out, 0} -> {:ok, String.trim(out)}
          _ -> {:error, "no Hugging Face token from OpenBao (bao-env)"}
        end

      helper ->
        case System.cmd(helper, []) do
          {out, 0} -> {:ok, String.trim(out)}
          _ -> {:error, "bao-hf-token gave no token"}
        end
    end
  end

  defp hf_get(tok, repo, file, out) do
    sh = ~s(curl -fsSL -H "Authorization: Bearer $HF_GET_TOKEN" -o "$2" "https://huggingface.co/$1/resolve/main/$3")

    with {:ok, _} <- cap("sh", ["-c", sh, "sh", repo, out, file], [{"HF_GET_TOKEN", tok}]) do
      if String.ends_with?(file, "SHA256SUMS"), do: File.read(out), else: {:ok, out}
    end
  end

  defp sum_for(sums, f) do
    sums |> String.split("\n") |> Enum.find_value(fn l ->
      case String.split(l) do
        [h, ^f] -> h
        [h, "*" <> ^f] -> h
        _ -> nil
      end
    end)
  end

  defp sha256(path) do
    case File.open(path, [:read, :binary]) do
      {:ok, io} ->
        h = IO.binstream(io, 8 * 1024 * 1024) |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
        File.close(io)
        {:ok, hex(:crypto.hash_final(h))}

      e ->
        e
    end
  end

  defp hex(b), do: Base.encode16(b, case: :lower)

  defp chmod_x(p) do
    case File.chmod(p, 0o755) do
      :ok -> {:cont, :ok}
      e -> {:halt, e}
    end
  end

  defp clean(d) do
    case File.rm_rf(d) do
      {:ok, _} -> File.mkdir_p(d)
      {:error, r, f} -> {:error, "cannot remove #{f}: #{r}"}
    end
  end

  defp need(d, names) do
    case Enum.reject(names, &File.exists?(Path.join(d, &1))) do
      [] -> :ok
      miss -> {:error, "missing in #{d}: #{Enum.join(miss, " ")}"}
    end
  end

  # gh run download keeps each artifact in its own folder; the libraries go beside each other
  # (a .framework is a folder: move it whole, never the files inside it).
  defp flatten_libs(d) do
    Path.wildcard(Path.join(d, "*/**/libgodot_riscv.*"))
    |> Enum.reject(&(Path.relative_to(&1, d) |> Path.dirname() |> String.contains?(".framework")))
    |> Enum.reduce_while(:ok, fn p, _ ->
      case File.rename(p, Path.join(d, Path.basename(p))) do
        :ok -> {:cont, :ok}
        e -> {:halt, e}
      end
    end)
  end

  defp source(ctx, line) do
    IO.puts("  " <> line)
    File.write(Path.join(ctx.dir, "SOURCES.txt"), line <> "\n", [:append])
  end
end

System.halt(Release.main(System.argv()))
