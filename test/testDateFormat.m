
javaDate = javaObject('java.util.Date');
offsetInMinutes = javaDate.getTimezoneOffset();

s = JSON.datenum2string(736368);
assert(strcmp(s, '2016-02-08'));

n = JSON.datestring2num('2016-02-08');
assert(n == 736368);

s = JSON.datenum2string(736368.5);
assert(s == 736368.5);

expected = 736368 + 1/2 + 1/24/60*(30+1/2);
s = JSON.datetimenum2string(expected);
actual = JSON.datetimestring2num(s);
assert(expected == actual);

n = JSON.datestring2num('2016-02-08T12:00Z');
assert(strcmp(n, '2016-02-08T12:00Z'));

n = JSON.datestring2num('2016-02-08 12:00Z');
assert(strcmp(n, '2016-02-08 12:00Z'));

%n = JSON.datetimestring2num('2016-02-08T12Z');
%assert(n == 736368.5);

%n = JSON.datetimestring2num('2016-02-08T12+0000');
%assert(n == 736368.5);

%n = JSON.datetimestring2num('2016-02-08T13+0100');
%assert(n == 736368.5);

%n = JSON.datetimestring2num('2016-02-08T12:30:30+0100');
%assert(n == 736368 + n_12_30_30);

n = JSON.datetimestring2num('2016-02-08T13:00+foo');
assert(strcmp(n, '2016-02-08T13:00+foo'));