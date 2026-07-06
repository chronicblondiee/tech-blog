# chronicblondiee.tech

Source for my technical blog, hosted on GitHub Pages as plain static HTML/CSS
(no build step, no Jekyll).

**Live site:** https://chronicblondiee.github.io/tech-blog/

## Layout

```
index.html    — blog homepage / post index
style.css     — shared stylesheet
posts/        — individual blog posts
poc/          — source for proof-of-concept work referenced in posts
```

## Posts

- [The Keytab Vault: Diskless Bare-Metal Linux with AD Auth via SSSD](posts/stateless-bare-metal-linux-sssd.html)
  — writeup of the POC in [`poc/stateless-sssd-poc`](poc/stateless-sssd-poc),
  a PXE RAM-boot architecture for stateless bare-metal Linux fleets
  authenticating against Active Directory via SSSD, with keytabs pulled from
  an Infisical vault at boot time instead of living on disk.
