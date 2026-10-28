-- HW5 statistics (run by stats.py; also usable directly in Cloud SQL Studio)
-- 1. successful vs unsuccessful
SELECT SUM(status_code = 200) AS successful, SUM(status_code <> 200) AS unsuccessful, COUNT(*) AS total FROM requests;
SELECT error_code, COUNT(*) AS n FROM failed_requests GROUP BY error_code ORDER BY n DESC;
-- 2. requests from banned countries
SELECT SUM(is_banned) AS from_banned_countries FROM requests;
SELECT country, COUNT(*) AS n FROM requests WHERE is_banned GROUP BY country ORDER BY n DESC;
-- 3. male vs female
SELECT gender, COUNT(*) AS n FROM requests GROUP BY gender ORDER BY n DESC;
-- 4. top 5 countries
SELECT country, COUNT(*) AS n FROM requests GROUP BY country ORDER BY n DESC, country LIMIT 5;
-- 5. requests per age group (first row = most requests)
SELECT age_group, COUNT(*) AS n FROM requests GROUP BY age_group ORDER BY n DESC;
-- 6. requests per income group (first row = most requests)
SELECT income_group, COUNT(*) AS n FROM requests GROUP BY income_group ORDER BY n DESC;
