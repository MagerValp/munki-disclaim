#include <signal.h>
#include <spawn.h>
#include <unistd.h>
#include <sysexits.h>
#import <Foundation/Foundation.h>


int responsibility_spawnattrs_setdisclaim(posix_spawnattr_t attrs, int disclaim)
    __attribute__((availability(macos,introduced=10.14), weak_import));

// Category for NSArray that returns a plain C array of char * from an
// NSArray with NSStrings
@interface NSArray (CArrayCategory)

- (char **)getCArray;

@end

@implementation NSArray (CArrayCategory)

- (char **)getCArray
{
    NSUInteger count = [self count];
    char **array = (char **)malloc((count + 1) * sizeof(char *));

    for (unsigned i = 0; i < count; i++) {
         array[i] = strdup([[self objectAtIndex:i] UTF8String]);
    }
    array[count] = NULL;
    return array;
}

@end


NSString *shimmedFlg = @"--shimmed";
NSString *munkiPythonPath = @"/usr/local/munki/munki-python";

// Global ObjC literals are only supported on macOS 11 and up.
// Move to local scope to support older macOS releases.
NSArray *allowedCmds = @[
    @"appusaged",
    @"app_usage_monitor",
    @"authrestartd",
    @"launchapp",
    @"logouthelper",
    @"managedsoftwareupdate",
    @"supervisor"
];


int execPython(NSArray<NSString *> *args) {
    // FIXME: This logic is wrong
    NSString *cmd = [args[0] lastPathComponent];
    if (! [allowedCmds containsObject:cmd]) {
        printf("Unknown cmd: %s\n", args[0].UTF8String);
        exit(EPERM);
    }

    // FIXME: This is the wrong approach
    NSString *absPath = [NSString stringWithFormat:@"/usr/local/munki/%@", cmd];
    if (! [args[1] isEqualToString:absPath]) {
        printf("Unknown path: %s\n", args[0].UTF8String);
        exit(EPERM);
    }

    // copy args and replace ".../{cmd} --shimmed" with ".../munki-python .../{cmd}.py"
    NSMutableArray *newArgs = [args mutableCopy];
    [newArgs removeObjectAtIndex:0];
    [newArgs replaceObjectAtIndex:0 withObject:[NSString stringWithFormat:@"%@.py", args[0]]];

    char **new_argv = [newArgs getCArray];
    if (execvp(new_argv[0], &new_argv[0]) == -1) {
        return errno;
    }
    return 0;
}

#define POSIX_CHECK(expr) \
    if ((err = (expr))) { \
        exit(err); \
    }

int execShimmed(NSArray<NSString *> *args, char *const *envp) {
    int err;
    
    // set argv to "--shimmed" + argv
    NSMutableArray *newArgs = [args mutableCopy];
    [newArgs insertObject:shimmedFlg atIndex:1];
    char **new_argv = [newArgs getCArray];
    
    // init posix attr
    posix_spawnattr_t attr;
    POSIX_CHECK(posix_spawnattr_init(&attr));
    
    // act like execve(2)
    short flags = POSIX_SPAWN_SETEXEC;
    
    // reset signal mask
    sigset_t sig_mask;
    sigemptyset(&sig_mask);
    POSIX_CHECK(posix_spawnattr_setsigmask(&attr, &sig_mask));
    flags |= POSIX_SPAWN_SETSIGMASK;
    
    // reset signals to default behavior
    sigset_t sig_default;
    sigfillset(&sig_default);
    POSIX_CHECK(posix_spawnattr_setsigdefault(&attr, &sig_default));
    flags |= POSIX_SPAWN_SETSIGDEF;
    
    // set flags
    POSIX_CHECK(posix_spawnattr_setflags(&attr, flags));
    
    // force TCC responsibility on child
    if (@available(macOS 10.14, *)) {
        POSIX_CHECK(responsibility_spawnattrs_setdisclaim(&attr, 1));
    }
    
    // exec shimmed process
    err = posix_spawn(NULL, new_argv[0], NULL, &attr, new_argv, envp);
    
    // clean up attr
    posix_spawnattr_destroy(&attr);
    
    return err;
}


int main(int argc, char * const argv[], char *const *envp) {
    NSArray<NSString *> *args = [[NSProcessInfo processInfo] arguments];
    
    // If we're called with --shimmed the child has been disclaimed and we
    // execute python with the original command, dropping --shimmed.
    if (args.count > 1 && [args[1] isEqualToString:shimmedFlg]) {
        return execPython(args);
    } else {
        // Otherwise we call the disclaim logic and add a --shimmed argument.
        return execShimmed(args, envp);
    }
}
