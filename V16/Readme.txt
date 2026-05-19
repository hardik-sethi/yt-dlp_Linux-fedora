TO Install-
    which yt-dlp
    yt-dlp --version
    pipx runpip yt-dlp show yt-dlp-ejs

To run-
    chmod +x yt-grab.sh
    ./yt-grab.sh

to maintain -
    # Monthly, or when YouTube downloads start failing:
    pipx upgrade yt-dlp

    # If yt-dlp breaks specifically on YouTube (anti-bot updates):
    pipx upgrade yt-dlp        # often this alone fixes it

    # Nuclear option if something gets weird:
    pipx reinstall yt-dlp

    # Verify ejs is still present after upgrades:
    pipx runpip yt-dlp show yt-dlp-ejs
