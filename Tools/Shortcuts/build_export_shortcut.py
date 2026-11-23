#!/usr/bin/env python3
"""Generate an unsigned Apple Shortcuts workflow; sign it with `shortcuts sign`."""
import pathlib
import plistlib
import uuid

ROOT = pathlib.Path(__file__).resolve().parents[2]
ACTIONS = []


def identifier(name):
    return str(uuid.uuid5(uuid.NAMESPACE_URL, 'https://slipcast.app/shortcuts/' + name)).upper()


def action(name, **parameters):
    ACTIONS.append({'WFWorkflowActionIdentifier': 'is.workflow.actions.' + name,
                    'WFWorkflowActionParameters': parameters})


def output(name, label='Text'):
    return {'Type': 'ActionOutput', 'OutputUUID': identifier(name), 'OutputName': label}


def attachment(value):
    return {'WFSerializationType': 'WFTextTokenAttachment', 'Value': value}


def text(prefix, value, suffix=''):
    return {'WFSerializationType': 'WFTextTokenString', 'Value': {
        'string': prefix + '\ufffc' + suffix,
        'attachmentsByRange': {'{%d, 1}' % len(prefix): value}}}


action('comment', WFCommentActionText=(
    'Export followed shows from Apple Podcasts for SlipCast. Allow access to Podcasts, '
    'then choose where to save Apple Podcasts.opml. In SlipCast, open Settings > '
    'Import Followed Shows > Choose OPML File. This exports subscriptions only, '
    'not listening history. No web requests or uploads are used by this shortcut.'))
action('getpodcastsfromlibrary', UUID=identifier('podcasts'))
action('repeat.each', GroupingIdentifier=identifier('loop'), WFControlFlowMode=0,
       WFInput=attachment(output('podcasts', 'Podcasts')))
# Only feed URLs are needed. Escape every XML attribute metacharacter, including
# ampersands in query strings. Names/artwork are fetched by SlipCast from the feeds.
value = {'Type': 'Variable', 'VariableName': 'Repeat Item', 'Aggrandizements': [
    {'Type': 'WFPropertyVariableAggrandizement', 'PropertyName': 'Feed URL'}]}
for index, (character, escaped) in enumerate([
    ('&', '&amp;'), ('<', '&lt;'), ('>', '&gt;'), ('"', '&quot;'), ("'", '&apos;')
]):
    name = 'escape-' + str(index)
    action('text.replace', UUID=identifier(name), WFInput=attachment(value),
           WFReplaceTextFind=character, WFReplaceTextReplace=escaped,
           WFReplaceTextRegularExpression=False, WFReplaceTextCaseSensitive=True)
    value = output(name, 'Updated Text')
action('gettext', UUID=identifier('outline'),
       WFTextActionText=text('    <outline type="rss" xmlUrl="', value, '"/>'))
action('repeat.each', GroupingIdentifier=identifier('loop'), WFControlFlowMode=2,
       UUID=identifier('results'))
action('gettext', UUID=identifier('opml'), WFTextActionText=text(
    '<?xml version="1.0" encoding="UTF-8"?>\n<opml version="2.0">\n'
    '<head><title>Apple Podcasts Subscriptions</title></head>\n<body>\n',
    output('results', 'Repeat Results'), '\n</body>\n</opml>'))
action('setitemname', UUID=identifier('file'), WFInput=attachment(output('opml')),
       WFName='Apple Podcasts.opml', WFDontIncludeFileExtension=False)
action('documentpicker.save', WFInput=attachment(output('file', 'Renamed Item')),
       WFAskWhereToSave=True, WFSaveFileOverwrite=False)

workflow = {
    'WFWorkflowActions': ACTIONS,
    'WFWorkflowClientVersion': '1505.3.0.2',
    'WFWorkflowMinimumClientVersion': 1106,
    'WFWorkflowMinimumClientVersionString': '1106',
    'WFWorkflowIcon': {'WFWorkflowIconGlyphNumber': 61440,
                       'WFWorkflowIconStartColor': -1448498689},
    'WFWorkflowImportQuestions': [], 'WFWorkflowInputContentItemClasses': [],
    'WFWorkflowOutputContentItemClasses': [], 'WFWorkflowTypes': [],
    'WFQuickActionSurfaces': [], 'WFWorkflowHasOutputFallback': False,
    'WFWorkflowHasShortcutInputVariables': False,
}
path = ROOT / 'Tools/Shortcuts/Export Apple Podcasts.unsigned.shortcut'
path.write_bytes(plistlib.dumps(workflow))
print(path)
