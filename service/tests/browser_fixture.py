"""Test-only simulated Google server; excluded from the deployment image."""
import os
from pathlib import Path
import tempfile


def create():
    if os.environ.get('HARNESS_ENABLE_TEST_GOOGLE') != '1':
        raise RuntimeError('This simulated Google service is for explicit local browser tests only.')
    from service.tests.test_service import system
    directory = tempfile.TemporaryDirectory(prefix='harness-browser-test-')
    fixture = system.__wrapped__(Path(directory.name))
    app, _ = next(fixture)
    app.state.fixture_directory = directory
    app.state.fixture_generator = fixture
    return app
