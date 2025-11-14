#!/usr/bin/env python3
"""
ACF Whip SessionStart Hook
Ensures task description style guide, task template, workflow docs, and backlog README are initialized.
"""
import json
import sys
from pathlib import Path


def check_and_copy(plugin_path: Path, target_path: Path) -> bool:
    """
    Check if target exists, if not copy from plugin content.

    Args:
        plugin_path: Path to file in plugin content directory
        target_path: Path where file should exist in project

    Returns:
        True if file was copied, False if it already existed
    """
    if not target_path.exists():
        target_path.parent.mkdir(parents=True, exist_ok=True)
        with open(plugin_path, 'r', encoding='utf-8') as f:
            content = f.read()
        with open(target_path, 'w', encoding='utf-8') as f:
            f.write(content)
        return True  # Was copied
    return False  # Already exists


def generate_backlog_readme(plugin_root: Path) -> None:
    """
    Generate .backlog/README.md with actual installed agents.

    Scans .claude/agents/ directory for installed agents and updates
    the {{IMPLEMENTER_AGENTS}} placeholder in the template.

    Args:
        plugin_root: Root directory of the plugin
    """
    template_path = plugin_root / "content" / "backlog" / "README.sample.md"
    target_path = Path(".backlog/README.md")

    if not template_path.exists():
        # Template not yet in plugin (will be created later)
        return

    # Read template
    with open(template_path, 'r', encoding='utf-8') as f:
        template = f.read()

    # Detect installed agents
    installed_agents = []
    agents_dir = Path(".claude/agents")
    if agents_dir.exists():
        for agent_file in agents_dir.glob("*.md"):
            agent_name = agent_file.stem
            # Skip hidden files
            if not agent_name.startswith('.'):
                installed_agents.append(agent_name)

    # Replace placeholders
    if installed_agents:
        agent_list = ", ".join(sorted(installed_agents))
    else:
        agent_list = "task-engineer, quality-reviewer"

    content = template.replace("{{IMPLEMENTER_AGENTS}}", agent_list)

    # Write customized README
    target_path.parent.mkdir(parents=True, exist_ok=True)
    with open(target_path, 'w', encoding='utf-8') as f:
        f.write(content)


def main() -> None:
    """Main entry point for SessionStart hook."""
    try:
        plugin_root = Path(__file__).parent.parent.parent

        # 1. Check/copy task description style guide
        check_and_copy(
            plugin_root / "content" / "style" / "task-descriptions.md",
            Path("docs/acf/style/task-descriptions.md")
        )

        # 2. Check/copy task template
        check_and_copy(
            plugin_root / "content" / "backlog" / "task-template.md",
            Path("docs/acf/backlog/task-template.md")
        )

        # 3. Check/copy workflow documentation
        check_and_copy(
            plugin_root / "content" / "backlog" / "workflow.md",
            Path("docs/acf/backlog/workflow.md")
        )

        # 4. Generate/update .backlog/README.md with installed agents
        backlog_warning = ""
        if Path(".backlog").exists():
            generate_backlog_readme(plugin_root)
        else:
            backlog_warning = "\n\n⚠️ **WARNING**: `.backlog/` directory not found. Run `/whip-init` to initialize backlog workflow, install agents, and configure quality gates.\n"

        # 5. Build context with style guide for immediate injection
        style_guide_path = Path("docs/acf/style/task-descriptions.md")
        if style_guide_path.exists():
            with open(style_guide_path, 'r', encoding='utf-8') as f:
                style_guide = f.read()

            additional_context = f"""# ACF Task Description Style Guide (Enforcement Active)

The following style guide is MANDATORY for all task descriptions. task-engineer and /task command MUST enforce these rules.

{style_guide}

**Enforcement**: Every task description will be validated against these rules. Violations result in immediate rejection.
{backlog_warning}"""
        else:
            additional_context = f"# ACF Whip Initialized\n\nRun /whip-init to set up backlog workflow.{backlog_warning}"

        # 6. Output SessionStart hook JSON
        result = {
            "hookSpecificOutput": {
                "hookEventName": "SessionStart",
                "additionalContext": additional_context
            }
        }

        print(json.dumps(result))
        sys.exit(0)

    except Exception as e:
        # Fail gracefully - don't break the session
        error_result = {
            "hookSpecificOutput": {
                "hookEventName": "SessionStart",
                "additionalContext": f"# ACF Whip Hook Error\n\nSessionStart hook encountered an error: {str(e)}\n\nYou can still use the plugin, but initialization may be incomplete."
            }
        }
        print(json.dumps(error_result))
        sys.exit(0)


if __name__ == "__main__":
    main()
