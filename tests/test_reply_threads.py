import importlib.util
from pathlib import Path


SERVER = Path(__file__).parents[1] / "viewer" / "server.py"
SPEC = importlib.util.spec_from_file_location("viewer_server_reply_threads", SERVER)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def mids(messages):
    return [message["mid"] for message in messages]


def test_thread_messages_places_sorted_replies_below_parent():
    messages = [
        {"mid": "root-1", "parent": None, "t": 10},
        {"mid": "reply-late", "parent": "root-1", "t": 30},
        {"mid": "root-2", "parent": None, "t": 40},
        {"mid": "reply-early", "parent": "root-1", "t": 20},
    ]

    threaded = MODULE.thread_messages(messages)

    assert mids(threaded) == ["root-1", "reply-early", "reply-late", "root-2"]
    assert [message["_thread_depth"] for message in threaded] == [0, 1, 1, 0]


def test_late_reply_does_not_move_root_after_newer_root():
    messages = [
        {"mid": "reply-a1", "parent": "root-a", "t": 300},
        {"mid": "root-b", "parent": None, "t": 200},
        {"mid": "root-a", "parent": None, "t": 100},
    ]

    assert mids(MODULE.thread_messages(messages)) == ["root-a", "reply-a1", "root-b"]


def test_orphan_reply_uses_own_sent_time_among_roots():
    messages = [
        {"mid": "root-b", "parent": None, "t": 200},
        {"mid": "orphan", "parent": "outside-window", "t": 150},
        {"mid": "root-a", "parent": None, "t": 100},
    ]

    threaded = MODULE.thread_messages(messages)

    assert mids(threaded) == ["root-a", "orphan", "root-b"]
    assert threaded[1]["_reply_orphan"] is True


def test_thread_messages_keeps_missing_parent_reply_as_marked_root():
    messages = [
        {"mid": "orphan", "parent": "outside-window", "t": 10},
        {"mid": "root", "parent": None, "t": 20},
    ]

    threaded = MODULE.thread_messages(messages)

    assert mids(threaded) == ["orphan", "root"]
    assert threaded[0]["_thread_depth"] == 0
    assert threaded[0]["_reply_orphan"] is True


def test_thread_messages_preserves_flat_order_without_replies():
    messages = [
        {"mid": "one", "parent": None, "t": 10},
        {"mid": "two", "parent": None, "t": 20},
        {"mid": "three", "parent": None, "t": 30},
    ]

    assert mids(MODULE.thread_messages(messages)) == ["one", "two", "three"]


def test_nested_replies_flatten_to_one_level_under_top_parent():
    messages = [
        {"mid": "root", "parent": None, "t": 10},
        {"mid": "child", "parent": "root", "t": 20},
        {"mid": "grandchild", "parent": "child", "t": 30},
    ]

    threaded = MODULE.thread_messages(messages)

    assert mids(threaded) == ["root", "child", "grandchild"]
    assert [message["_thread_depth"] for message in threaded] == [0, 1, 1]


def test_parse_km_reply_parent_and_current_text():
    content = (
        '{"ncustomtype":"reply","ncustomdata":{"message":{"chatMsg":"current"}},'
        '"ncustomdataList":{"ncustomdata":[{"message":{"msgId":123,"chatMsg":"quoted"}}]}}'
    )

    assert MODULE.parse_reply_parent(content) == "123"
    assert MODULE.clean(content) == "current"
