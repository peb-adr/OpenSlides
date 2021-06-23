# Generated by jsangmeister on 2021-03-18 16:27

from django.db import migrations

from ...poll.migrations.vote_migration_helper import set_user_tokens


class Migration(migrations.Migration):

    dependencies = [
        ("motions", "0038_motionvote_user_token_1"),
    ]

    operations = [
        migrations.RunPython(set_user_tokens("motions", "MotionVote")),
    ]