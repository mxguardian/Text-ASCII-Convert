# Text-ASCII-Convert

## Release process

1. Bump `$VERSION` in `lib/Text/ASCII/Convert.pm`
2. Commit and tag: `git tag v<version>`
3. Push both: `git push origin main && git push origin v<version>`
4. Build the distribution tarball: `tools/build.sh` (runs the tests, regenerates
   `README.md` from the POD, and produces `Text-ASCII-Convert-<version>.tar.gz`)
5. Upload to CPAN manually: `cpan-upload Text-ASCII-Convert-<version>.tar.gz`
