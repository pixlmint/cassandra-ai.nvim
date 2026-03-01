import random

import pytest

from fim.types import FIMConfig, FIMExample, FIM_CONFIGS


@pytest.fixture
def qwen_config():
    return FIM_CONFIGS["qwen2.5-coder"]


@pytest.fixture
def codellama_config():
    return FIM_CONFIGS["codellama"]


@pytest.fixture
def seed_rng():
    random.seed(42)


@pytest.fixture
def simple_class_php():
    return """\
<?php

namespace App\\Services;

use App\\Models\\User;
use App\\Repositories\\UserRepository;

class UserService
{
    private UserRepository $repo;

    public function __construct(UserRepository $repo)
    {
        $this->repo = $repo;
    }

    public function findActive(): array
    {
        $users = $this->repo->findAll();
        $active = [];
        foreach ($users as $user) {
            if ($user->isActive()) {
                $active[] = $user;
            }
        }
        return $active;
    }

    public function deactivate(User $user): void
    {
        $user->setActive(false);
        $this->repo->save($user);
    }
}
"""


@pytest.fixture
def class_with_comments_php():
    return """\
<?php

namespace App\\Handlers;

class OrderHandler
{
    // Validate the order total against the budget
    public function validate(Order $order): bool
    {
        return $order->getTotal() > 0;
    }

    // Process payment and update status
    public function process(Order $order): void
    {
        $order->setStatus('processing');
        $order->charge();
    }
}
"""


@pytest.fixture
def class_with_brackets_php():
    return """\
<?php

namespace App\\Config;

class Settings
{
    public function getDefaults(): array
    {
        return [
            'timeout' => 30,
            'retries' => 3,
            'cache' => true,
            'debug' => false,
        ];
    }

    public function merge(array $base, array $override): array
    {
        return array_merge($base, $override);
    }
}
"""


@pytest.fixture
def dependency_target_php():
    """A controller that uses UserService — the consumer side."""
    return """\
<?php

namespace App\\Controllers;

use App\\Services\\UserService;
use App\\Models\\User;

class UserController
{
    private UserService $service;

    public function __construct(UserService $service)
    {
        $this->service = $service;
    }

    public function index(): array
    {
        return $this->service->findActive();
    }

    public function delete(int $id): void
    {
        $user = $this->service->findById($id);
        $this->service->deactivate($user);
    }
}
"""


@pytest.fixture
def dependency_provider_php():
    """UserService with findUser/deleteUser/listUsers — the provider side."""
    return """\
<?php

namespace App\\Services;

use App\\Models\\User;
use App\\Repositories\\UserRepository;

class UserService
{
    private UserRepository $repo;

    public function findUser(int $id): ?User
    {
        return $this->repo->find($id);
    }

    public function deleteUser(int $id): void
    {
        $this->repo->delete($id);
    }

    public function listUsers(): array
    {
        return $this->repo->findAll();
    }
}
"""


@pytest.fixture
def class_with_doc_comments_php():
    return """\
<?php

namespace App\\Services;

use App\\Models\\User;

class UserService
{
    /**
     * Find a user by their ID.
     *
     * @param int $id The user ID
     * @return User|null
     * @throws NotFoundException
     */
    public function findById(int $id): ?User
    {
        return $this->repo->find($id);
    }

    /**
     * Deactivate a user account.
     *
     * @param User $user The user to deactivate
     * @return void
     */
    public function deactivate(User $user): void
    {
        $user->setActive(false);
        $this->repo->save($user);
    }

    // This is just a regular comment
    public function count(): int
    {
        return $this->repo->count();
    }
}
"""


@pytest.fixture
def large_function_php():
    """PHP class with a 50-line function body — for testing oversized span splitting."""
    body_lines = []
    for i in range(1, 51):
        body_lines.append(f"        $result_{i} = $this->process({i});")
    body = "\n".join(body_lines)
    return f"""\
<?php

namespace App\\Services;

class DataProcessor
{{
    private array $data;

    public function processAll(): array
    {{
{body}
        return $result_50;
    }}

    public function reset(): void
    {{
        $this->data = [];
    }}
}}
"""


def make_example(
    prefix="<?php\n\nfunction foo() {\n",
    middle="    return 42;\n",
    suffix="}\n",
    filepath="src/Example.php",
    span_kind="function_body",
    span_name="foo",
    cross_file_context="",
    complexity_score=0.0,
) -> FIMExample:
    """Quick FIMExample builder with sensible defaults."""
    mid_lines = middle.count("\n") + 1
    total_lines = (prefix + middle + suffix).count("\n") + 1
    return FIMExample(
        filepath=filepath,
        span_kind=span_kind,
        span_name=span_name,
        prefix=prefix,
        middle=middle,
        suffix=suffix,
        cross_file_context=cross_file_context,
        complexity_score=complexity_score,
        middle_lines=mid_lines,
        total_lines=total_lines,
    )
