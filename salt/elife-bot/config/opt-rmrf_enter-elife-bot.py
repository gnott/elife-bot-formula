import rmrf_enter
from rmrf_enter import has_ymd_pattern, older_than_N_days

def files_to_delete():
    return [
        # 'debug' files that accumulate
        ("delete", "/tmp/", \
            lambda fname: has_ymd_pattern(fname) and older_than_N_days(fname, days=7)),
    ]

if __name__ == '__main__':
    rmrf_enter.do_stuff(files_to_delete())
