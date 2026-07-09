# MySQL Fixture Testing

Date: 2026-07-09

## Goal

Perfect-MySQL live tests should not depend on private sample data, passwordless
root access, or application-specific schemas. The current direction is a
disposable generic ecommerce fixture:

- create a test schema
- load `sample_catalog_cart.sql`
- run dynamic CRUD and connector tests
- drop the schema

## Fixture Shape

The fixture lives in the Perfect-MySQL test target at:

`Tests/PerfectMySQLTests/Fixtures/sample_catalog_cart.sql`

It creates a small catalog/cart model:

- `catalog_categories`
- `catalog_products`
- `catalog_variants`
- `catalog_customers`
- `catalog_carts`
- `catalog_cart_items`

The generated dataset currently includes 120 products, 360 variants, 40
customers, 80 carts, and 240 cart items.

## Local/CI Configuration

Default `swift test` remains safe and offline. Destructive MySQL fixture tests
only run when explicitly enabled:

```bash
MYSQL_FIXTURE_TESTS=1 \
MYSQL_TEST_HOST=localhost \
MYSQL_TEST_DATABASE=perfect_mysql_fixture \
MYSQL_TEST_USER=lassouser \
MYSQL_TEST_PASSWORD='...' \
swift test
```

`MYSQL_TEST_DATABASE` is treated as a schema-name prefix; each fixture test
adds a unique suffix so Swift Testing can run live fixture tests in parallel.

The test user should have enough privilege to create and drop schemas matching
that prefix, for example `perfect_mysql_fixture_%`. It should not be a
production or corpus datasource account.

For CI, prefer a freshly started MySQL service/container and a throwaway test
user/schema. Do not recreate the old passwordless-root assumption.

## Verified Locally

The fixture-enabled suite passes against the local MySQL server using the
create/drop-capable `lassouser` account:

- legacy XCTest suite: 51 tests passed
- Swift Testing suite: 4 tests passed
- generic catalog/cart fixture schema created, loaded, queried, and dropped
- dynamic row conversion/select path verified against a disposable schema

The read-only `perfect` account is still appropriate for real datasource smoke
tests, but it is intentionally insufficient for this destructive fixture suite.
