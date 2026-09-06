# チーム標準のスキル

ここに置いたスキルは `git pull && mise run setup` で全員に配られ、サンドボックス内の
エージェントのスキル置き場に現れます（claude なら `~/.claude/skills/`、codex なら
`~/.agents/skills/`、copilot なら `$COPILOT_HOME/skills/`）。

個人のスキル（clone した中の `local/skills/`）と**同名の場合は個人が優先**されます。
自分で置いたものが効く方が驚きが少ないためです。影に入ったものは作成時のログに出ます。

置くのは「チームで手順を揃えたいスキル」だけにしてください。自分だけで使うスキルは
`local/skills/` に置きます（[手順](../../local/README.md#スキル)）。
